import Darwin
import Foundation

// Owns one pseudo-terminal pair and its child process. The child is spawned
// with posix_spawn onto the replica side (dup'd to stdin/stdout/stderr in a
// fresh session); the primary side is drained by a dispatch read source.
// Mutable state is confined to a private serial queue, and both callbacks
// fire on background queues, so callers hop to the main actor themselves.

final class PTYProcess {
    struct LaunchError: Error {
        let message: String
    }

    private static let queueLabel = "io.github.bhino50.FinderPath.pty"
    private static let readChunkSize = 4096
    /// Grace period between SIGHUP and SIGKILL in terminate().
    private static let killGracePeriod: DispatchTimeInterval = .seconds(2)
    private static let forcedTerm = "xterm-256color"
    private static let fallbackLanguage = "en_US.UTF-8"
    private static let fallbackShell = "/bin/zsh"

    // MARK: - Launch configuration

    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String
    private let environmentOverrides: [String: String]

    // MARK: - Queue-confined state

    /// Guards every var below. Code already running on this queue must use
    /// the backing storage directly; the public accessors would deadlock.
    private let stateQueue = DispatchQueue(label: PTYProcess.queueLabel + ".state")
    private let readQueue = DispatchQueue(label: PTYProcess.queueLabel + ".read")

    private var outputHandler: (([UInt8]) -> Void)?
    private var exitHandler: ((Int32) -> Void)?
    private var runningFlag = false
    private var childPID: pid_t = -1
    private var primaryDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var currentRows: Int
    private var currentColumns: Int

    // MARK: - Public surface

    /// Fires on a background queue with each chunk read from the PTY.
    var onOutput: (([UInt8]) -> Void)? {
        get { stateQueue.sync { outputHandler } }
        set { stateQueue.sync { outputHandler = newValue } }
    }

    /// Fires once on a background queue with the child's exit code
    /// (128 + signal number when the child was killed by a signal).
    var onExit: ((Int32) -> Void)? {
        get { stateQueue.sync { exitHandler } }
        set { stateQueue.sync { exitHandler = newValue } }
    }

    private(set) var isRunning: Bool {
        get { stateQueue.sync { runningFlag } }
        set { stateQueue.sync { runningFlag = newValue } }
    }

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        rows: Int,
        columns: Int
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environment
        self.currentRows = max(rows, 1)
        self.currentColumns = max(columns, 1)
    }

    deinit {
        // The cancel handler owns closing the descriptor; SIGHUP covers a
        // child that outlives its owner so orphaned shells do not linger.
        readSource?.cancel()
        if childPID > 0 {
            kill(childPID, SIGHUP)
        }
    }

    // MARK: - Lifecycle

    /// Spawns the child once; later calls while running are no-ops.
    func launch() throws {
        try stateQueue.sync {
            guard !runningFlag else { return }
            try launchOnQueue()
        }
    }

    private func launchOnQueue() throws {
        var primary: Int32 = -1
        var replica: Int32 = -1
        guard openpty(&primary, &replica, nil, nil, nil) == 0 else {
            throw LaunchError(message: "openpty failed: \(Self.message(forErrno: errno))")
        }

        var spawned = false
        defer {
            // The parent never keeps the replica; on failure the primary
            // goes too so a failed launch leaks no descriptors.
            close(replica)
            if !spawned {
                close(primary)
            }
        }

        // The child must not inherit the primary side of its own PTY.
        _ = fcntl(primary, F_SETFD, FD_CLOEXEC)
        Self.applyWindowSize(rows: currentRows, columns: currentColumns, to: primary)

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LaunchError(message: "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try Self.checkSetup(posix_spawn_file_actions_adddup2(&fileActions, replica, 0), "dup stdin")
        try Self.checkSetup(posix_spawn_file_actions_adddup2(&fileActions, replica, 1), "dup stdout")
        try Self.checkSetup(posix_spawn_file_actions_adddup2(&fileActions, replica, 2), "dup stderr")
        if replica > 2 {
            try Self.checkSetup(posix_spawn_file_actions_addclose(&fileActions, replica), "close replica")
        }
        try Self.checkSetup(
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory),
            "chdir to \(workingDirectory)"
        )

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LaunchError(message: "posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.checkSetup(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)), "set SETSID")

        var argv = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp = Self.mergedEnvironment(environmentOverrides).map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = -1
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard spawnResult == 0 else {
            throw LaunchError(message: "posix_spawn \(executable) failed: \(Self.message(forErrno: spawnResult))")
        }

        spawned = true
        childPID = pid
        primaryDescriptor = primary
        runningFlag = true
        startReading(from: primary)
        reapExit(of: pid)
    }

    private static func checkSetup(_ result: Int32, _ step: String) throws {
        guard result == 0 else {
            throw LaunchError(message: "spawn setup failed (\(step)): \(message(forErrno: result))")
        }
    }

    // MARK: - Input

    /// Ignored when the child is not running. Handles partial writes and
    /// EINTR; remaining bytes are dropped if the descriptor goes away.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self, self.runningFlag, self.primaryDescriptor >= 0 else { return }
            Self.writeFully(bytes, to: self.primaryDescriptor)
        }
    }

    private static func writeFully(_ bytes: [UInt8], to descriptor: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    // MARK: - Resize

    func resize(rows: Int, columns: Int) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.currentRows = max(rows, 1)
            self.currentColumns = max(columns, 1)
            guard self.primaryDescriptor >= 0 else { return }
            Self.applyWindowSize(rows: self.currentRows, columns: self.currentColumns, to: self.primaryDescriptor)
        }
    }

    /// TIOCSWINSZ also raises SIGWINCH in the child's foreground group.
    private static func applyWindowSize(rows: Int, columns: Int, to descriptor: Int32) {
        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = withUnsafeMutablePointer(to: &size) { pointer in
            ioctl(descriptor, TIOCSWINSZ, pointer)
        }
    }

    // MARK: - Termination

    /// Asks the child to hang up, then force-kills it if it is still around
    /// after the grace period. Safe to call at any time.
    func terminate() {
        stateQueue.async { [weak self] in
            guard let self, self.runningFlag, self.childPID > 0 else { return }
            let pid = self.childPID
            kill(pid, SIGHUP)
            self.stateQueue.asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak self] in
                guard let self, self.runningFlag, self.childPID == pid else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Output draining

    private func startReading(from descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        source.setEventHandler { [weak self] in
            self?.drainOutput(from: descriptor)
        }
        // The cancel path is the single owner of the close, whichever side
        // (EOF, read error, deinit) triggers teardown.
        source.setCancelHandler {
            close(descriptor)
        }
        readSource = source
        source.resume()
    }

    private func drainOutput(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        let bytesRead = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        if bytesRead > 0 {
            onOutput?(Array(buffer.prefix(bytesRead)))
            return
        }
        if bytesRead == -1 && (errno == EINTR || errno == EAGAIN) {
            return
        }
        stopReading() // EOF or unrecoverable read error
    }

    /// Cancels the read source; its cancel handler closes the descriptor.
    private func stopReading() {
        stateQueue.sync {
            readSource?.cancel()
            readSource = nil
            primaryDescriptor = -1
        }
    }

    // MARK: - Exit

    private func reapExit(of pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var result: pid_t = -1
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR
            self?.finishExit(waitStatus: result == pid ? status : -1)
        }
    }

    private func finishExit(waitStatus: Int32) {
        let handler: ((Int32) -> Void)? = stateQueue.sync {
            runningFlag = false
            childPID = -1
            return exitHandler
        }
        handler?(Self.exitCode(fromWaitStatus: waitStatus))
    }

    /// WIFEXITED/WEXITSTATUS are macros the Swift importer drops: the low
    /// 7 bits of the wait status carry a terminating signal (0 for a normal
    /// exit) and the next 8 bits carry the exit status. Signal deaths map
    /// to 128 + signal, matching shell conventions.
    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        guard signal == 0 else { return 128 + signal }
        return (status >> 8) & 0xFF
    }

    // MARK: - Environment

    static func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let record = getpwuid(getuid()), let shellField = record.pointee.pw_shell {
            let shell = String(cString: shellField)
            if !shell.isEmpty {
                return shell
            }
        }
        return fallbackShell
    }

    /// Caller overrides win over the inherited environment; TERM is always
    /// forced so the emulator and the child agree on capabilities, and a
    /// UTF-8 LANG is supplied when none is set.
    private static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            merged[key] = value
        }
        merged["TERM"] = forcedTerm
        if (merged["LANG"] ?? "").isEmpty {
            merged["LANG"] = fallbackLanguage
        }
        return merged
    }

    private static func message(forErrno code: Int32) -> String {
        String(cString: strerror(code))
    }
}
