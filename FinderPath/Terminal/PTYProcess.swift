import Darwin
import Foundation

// Owns one pseudo-terminal pair and its child process. The child is spawned
// with posix_spawn onto the replica side (dup'd to stdin/stdout/stderr in a
// fresh session); the primary side is drained by a dispatch read source.
// Mutable state is confined to a private serial queue, and both callbacks
// fire on background queues, so callers hop to the main actor themselves.

final class PTYProcess: @unchecked Sendable {
    struct LaunchError: Error {
        let message: String
    }

    private static let queueLabel = "io.github.bhino50.FinderPath.pty"
    private static let readChunkSize = 4096
    /// Grace period between SIGHUP and SIGKILL in terminate().
    private static let killGracePeriod: DispatchTimeInterval = .seconds(2)
    private static let forcedTerm = "xterm-256color"
    private static let fallbackLanguage = "en_US.UTF-8"
    private nonisolated static let fallbackShell = "/bin/zsh"

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
    // Writes run on their own queue and poll a nonblocking descriptor. They
    // must never hold stateQueue while waiting, or they would stall draining,
    // resize, and termination.
    private let writeQueue = DispatchQueue(label: PTYProcess.queueLabel + ".write")

    private var outputHandler: (([UInt8]) -> Void)?
    private var exitHandler: ((Int32) -> Void)?
    private var runningFlag = false
    private var terminatingFlag = false
    private var childPID: pid_t = -1
    private var primaryDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var currentRows: Int
    private var currentColumns: Int
    /// Bumped on each successful launch so a delayed terminate() timer never
    /// signals a PID that a later launch (or the OS) may have reused.
    private var launchGeneration = 0

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
        Self.signalSessionMembers(Self.sessionMembers(ledBy: childPID), ledBy: childPID, signal: SIGHUP)
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
        var nameBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard openpty(&primary, &replica, &nameBuffer, nil, nil) == 0 else {
            throw LaunchError(message: "openpty failed: \(Self.message(forErrno: errno))")
        }
        let ttyPath = String(cString: nameBuffer)

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
        guard fcntl(primary, F_SETFD, FD_CLOEXEC) == 0 else {
            throw LaunchError(message: "could not protect PTY descriptor inheritance: \(Self.message(forErrno: errno))")
        }
        // A child that temporarily stops reading must never wedge the serial
        // write queue. Nonblocking writes wait with poll and re-check launch
        // ownership, so terminate/restart can always make progress.
        let fileStatusFlags = fcntl(primary, F_GETFL)
        guard fileStatusFlags >= 0,
              fcntl(primary, F_SETFL, fileStatusFlags | O_NONBLOCK) == 0 else {
            throw LaunchError(message: "could not make PTY nonblocking: \(Self.message(forErrno: errno))")
        }
        Self.applyWindowSize(rows: currentRows, columns: currentColumns, to: primary)

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LaunchError(message: "posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // Open the replica fresh in the child (fd 0) rather than dup'ing the
        // inherited descriptor. With POSIX_SPAWN_SETSID applied first, the
        // child is a session leader, so opening the tty without O_NOCTTY makes
        // it the controlling terminal — the prerequisite for job control,
        // /dev/tty, and Ctrl-C delivering signals to the foreground group.
        try Self.checkSetup(posix_spawn_file_actions_addopen(&fileActions, 0, ttyPath, O_RDWR, 0), "open controlling tty")
        try Self.checkSetup(posix_spawn_file_actions_adddup2(&fileActions, 0, 1), "dup stdout")
        try Self.checkSetup(posix_spawn_file_actions_adddup2(&fileActions, 0, 2), "dup stderr")
        if replica > 2 {
            // The parent's replica fd is inherited at spawn; the child does not
            // need it since it opens the tty by path, so close it there too.
            try Self.checkSetup(posix_spawn_file_actions_addclose(&fileActions, replica), "close inherited replica")
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
        terminatingFlag = false
        launchGeneration += 1
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
        writeQueue.async { [weak self] in
            guard let self else { return }
            // Duplicate the descriptor while ownership is locked. The duplicate
            // cannot turn into an unrelated reused fd if the read source closes
            // the primary during this write.
            let snapshot: (descriptor: Int32, generation: Int)? = self.stateQueue.sync {
                guard self.runningFlag, !self.terminatingFlag, self.primaryDescriptor >= 0 else { return nil }
                // Unlike dup(), F_DUPFD_CLOEXEC prevents a concurrent spawn
                // from inheriting this temporary master descriptor.
                let descriptor = fcntl(self.primaryDescriptor, F_DUPFD_CLOEXEC, 0)
                guard descriptor >= 0 else { return nil }
                return (descriptor, self.launchGeneration)
            }
            guard let snapshot else { return }
            defer { close(snapshot.descriptor) }
            Self.writeFully(bytes, to: snapshot.descriptor) {
                self.stateQueue.sync {
                    self.runningFlag
                        && !self.terminatingFlag
                        && self.launchGeneration == snapshot.generation
                }
            }
        }
    }

    private static func writeFully(
        _ bytes: [UInt8],
        to descriptor: Int32,
        while shouldContinue: () -> Bool
    ) {
        var offset = 0
        while offset < bytes.count {
            guard shouldContinue() else { return }
            let written = bytes[offset...].withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard shouldContinue() else { return }
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = poll(&writable, 1, 100)
                if result == -1 && errno != EINTR { return }
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
        // Retain this owner through the delayed escalation. restart() replaces
        // the PTY immediately, and a weak cleanup task could otherwise vanish
        // before an uncooperative child or process group has actually exited.
        stateQueue.async { [self] in
            guard runningFlag, childPID > 0 else { return }
            let pid = childPID
            let generation = launchGeneration
            terminatingFlag = true
            // Snapshot every process in the shell's POSIX session before any
            // signal is delivered. Unlike a foreground PGID, this remains able
            // to identify a pipeline member after its group leader exits.
            let sessionMembers = Self.sessionMembers(ledBy: pid)
            Self.signalSessionMembers(sessionMembers, ledBy: pid, signal: SIGHUP)
            kill(pid, SIGHUP)
            // Closing the primary side delivers a terminal hangup and releases
            // readers even when the shell or a foreground child is misbehaving.
            readSource?.cancel()
            readSource = nil
            primaryDescriptor = -1
            stateQueue.asyncAfter(deadline: .now() + Self.killGracePeriod) { [self] in
                // A same-object relaunch changes the generation and invalidates
                // this cleanup. Each captured PID is revalidated against the
                // original session before escalation, protecting against reuse.
                guard launchGeneration == generation else { return }
                Self.signalSessionMembers(sessionMembers, ledBy: pid, signal: SIGKILL)
                if runningFlag, childPID == pid {
                    kill(pid, SIGKILL)
                }
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
            terminatingFlag = true
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

    /// Snapshot all live processes in the child shell's POSIX session using
    /// the public BSD process table. Capturing concrete PIDs before SIGHUP lets
    /// delayed cleanup safely handle pipelines whose group leader exits first.
    private nonisolated static func sessionMembers(ledBy sessionLeader: pid_t) -> [pid_t] {
        guard sessionLeader > 1 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<3 {
            var byteCount = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
                  byteCount > 0 else {
                break
            }
            // The process table can grow between the sizing and fill calls.
            byteCount += stride * 16
            var processes = [kinfo_proc](
                repeating: kinfo_proc(),
                count: max(byteCount / stride, 1)
            )
            var filledBytes = processes.count * stride
            let result = processes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &filledBytes, nil, 0)
            }
            if result == -1, errno == ENOMEM { continue }
            guard result == 0 else { break }

            var seen = Set<pid_t>()
            var members: [pid_t] = []
            for process in processes.prefix(filledBytes / stride) {
                let candidate = process.kp_proc.p_pid
                guard candidate > 1,
                      getsid(candidate) == sessionLeader,
                      seen.insert(candidate).inserted else { continue }
                members.append(candidate)
            }
            // Signal the session leader last so it stays available while the
            // membership checks for its descendants run.
            return members.sorted { lhs, rhs in
                if lhs == sessionLeader { return false }
                if rhs == sessionLeader { return true }
                return lhs < rhs
            }
        }
        return [sessionLeader]
    }

    private nonisolated static func signalSessionMembers(
        _ members: [pid_t],
        ledBy sessionLeader: pid_t,
        signal: Int32
    ) {
        for member in members where member > 1 && getsid(member) == sessionLeader {
            kill(member, signal)
        }
    }

    // MARK: - Environment

    nonisolated static func defaultShell() -> String {
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
