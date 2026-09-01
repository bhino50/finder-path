import Foundation

// One live terminal: a PTY-backed shell, a streaming parser, and a screen
// model. PTY callbacks arrive on a background queue and hop to the main
// actor before touching the parser or screen, so all mutable state stays
// main-actor confined. DSR replies are written back through the PTY here
// because the session is the only layer that owns both parser and process.

@MainActor
final class TerminalSession: Identifiable {
    enum Status: Equatable {
        case notStarted
        case starting
        case running
        case exited(Int32)
        case failed(String)
    }

    /// Grid size used until a view attaches and drives the real geometry.
    private static let defaultRows = 24
    private static let defaultColumns = 80

    let id: UUID
    var name: String
    var workingDirectory: String
    /// True once the user renames the session, which pins the name so the
    /// shell-provided title no longer overrides it.
    var hasCustomName = false

    private(set) var status: Status = .notStarted
    private(set) var screen: TerminalScreen

    /// Bumped whenever `screen` is replaced wholesale rather than mutated.
    ///
    /// Views hold absolute line numbers — selection anchors and the
    /// scrolled-back viewport — and those only mean anything within a single
    /// screen's lifetime. `restart()` swaps in a fresh screen on the *same*
    /// session object, so a view watching for a new session never notices and
    /// would keep applying dead line numbers to live text.
    private(set) var screenGeneration = 0

    var onScreenUpdate: (() -> Void)?
    var onStatusChange: (() -> Void)?
    /// Fires when the terminal title (OSC 0/2) changes, so the tab can follow
    /// the running task.
    var onTitleChange: (() -> Void)?

    /// The tab label: a manual rename wins; otherwise the shell's title (the
    /// running command or directory) when it has set one; otherwise the name.
    /// Capped so a very long title cannot stretch the tab strip or menu.
    var displayName: String {
        if hasCustomName { return name }
        let title = screen.title.trimmingCharacters(in: .whitespaces)
        let base = title.isEmpty ? name : title
        let maxLength = 28
        guard base.count > maxLength else { return base }
        return String(base.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private let shellPath: String
    private let scrollbackLimit: Int
    /// Optional command run once after the shell starts, e.g. a CLI agent like
    /// `claude`. Not persisted, so a restored session comes back as a plain
    /// shell rather than silently re-launching the agent.
    private let initialCommand: String?
    private var pty: PTYProcess?
    private var spawnTask: Task<Void, Never>?
    private var spawnGeneration = 0
    private var parser = TerminalParser()
    private var lastNotifiedTitle = ""
    /// A shell must not start until a real TerminalView has supplied its grid.
    /// Otherwise it emits the first prompt at the 80x24 fallback, then zsh has
    /// to redraw immediately when the panel's actual width arrives.
    private var hasPreparedViewport = false
    private var startWhenViewportIsReady = false

    init(
        id: UUID = UUID(),
        name: String,
        workingDirectory: String,
        shellPath: String = PTYProcess.defaultShell(),
        scrollbackLimit: Int = 2000,
        initialCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
        self.scrollbackLimit = scrollbackLimit
        self.initialCommand = initialCommand
        self.screen = TerminalScreen(
            rows: Self.defaultRows,
            columns: Self.defaultColumns,
            scrollbackLimit: scrollbackLimit
        )
    }

    // MARK: - Lifecycle

    /// Idempotent lazy spawn: only a session that has never run spawns here.
    /// Exited or failed sessions relaunch through restart() so the caller
    /// makes the retry explicit.
    func start() {
        guard status == .notStarted else { return }
        guard hasPreparedViewport else {
            startWhenViewportIsReady = true
            return
        }
        spawn()
    }

    func restart() {
        spawnGeneration += 1
        spawnTask?.cancel()
        spawnTask = nil
        pty?.terminate()
        pty = nil
        startWhenViewportIsReady = false
        parser = TerminalParser()
        screen = TerminalScreen(
            rows: screen.rows,
            columns: screen.columns,
            scrollbackLimit: scrollbackLimit
        )
        // Line numbering restarts with the screen; tell observers before they
        // redraw with anchors that belong to the screen just discarded.
        screenGeneration += 1
        onScreenUpdate?()
        spawn()
    }

    func terminate() {
        spawnGeneration += 1
        spawnTask?.cancel()
        spawnTask = nil
        // Status flips to .exited via the onExit callback so the exit code
        // shown in the UI is the real one, not a guess made here.
        pty?.terminate()
    }

    /// Hangs the child up on the caller's thread and returns the pre-signal
    /// POSIX-session snapshot so the caller can escalate every captured member.
    /// Used on app quit, where the normal asynchronous terminate() never gets
    /// to run before the process exits.
    @discardableResult
    func hangUp() -> PTYProcess.TerminationSnapshot? {
        // A session still validating its folder has no pty yet. Retire the
        // spawn so a launch that completes after this point is abandoned
        // rather than creating a shell that nothing will ever signal.
        spawnGeneration += 1
        spawnTask?.cancel()
        spawnTask = nil
        return pty?.hangUpSynchronously()
    }

    private func spawn() {
        guard spawnTask == nil else { return }
        spawnGeneration += 1
        let generation = spawnGeneration
        let directory = workingDirectory
        status = .starting
        onStatusChange?()

        spawnTask = Task { @MainActor [weak self] in
            let validation = await FinderPathDirectoryTarget.validate(directory)
            guard let self,
                  !Task.isCancelled,
                  self.spawnGeneration == generation else { return }

            guard validation.isAvailable else {
                self.spawnTask = nil
                self.status = .failed(Self.directoryFailureMessage(for: directory, validation: validation))
                self.onStatusChange?()
                return
            }

            await self.launchValidatedProcess(generation: generation)
        }
    }

    private static func directoryFailureMessage(
        for directory: String,
        validation: FinderPathDirectoryTarget.Validation
    ) -> String {
        switch validation {
        case .available:
            return ""
        case .unavailable:
            return "Working folder is unavailable: \(directory)"
        case .timedOut:
            return "Working folder is not responding: \(directory)"
        case .failed(let detail):
            return "Could not verify working folder \(directory): \(detail)"
        }
    }

    private enum LaunchResult: Sendable {
        case succeeded
        case failed(String)
    }

    private func launchValidatedProcess(generation: Int) async {
        let process = PTYProcess(
            executable: shellPath,
            arguments: ["-l"],
            workingDirectory: workingDirectory,
            environment: [:],
            rows: screen.rows,
            columns: screen.columns
        )
        // Install identity before launching off-main. A very short-lived child
        // can produce output or exit before the detached launch continuation
        // returns to the main actor; callbacks must already know its owner.
        pty = process

        // Identity checks drop late output or exits from a process that has
        // been replaced by restart(); without them a stale exit callback
        // could mark a freshly restarted session as dead.
        // PTY output is produced on one serial read queue. Dispatching that
        // queue directly onto the serial main queue preserves byte-chunk
        // order; separate unstructured Tasks may execute out of order and
        // split zsh's erase/cursor/redraw sequences during history recall
        // or a SIGWINCH resize burst.
        //
        // One main-queue block per 4 KB read let the queue grow without bound:
        // `cat` of a large file enqueued thousands of blocks faster than the
        // main thread could run them, each paying a dispatch and a copy. Bytes
        // now accumulate in order behind one pending drain; if that bounded
        // buffer fills, the serial read queue waits until the drain takes it.
        let outputBuffer = PTYOutputBuffer()
        process.onOutput = { [weak self, weak process] bytes in
            guard outputBuffer.appendAndClaimDrain(bytes) else { return }
            DispatchQueue.main.async {
                // Always drain, even when the session is gone, so the claim is
                // released and later output can schedule another drain.
                let pending = outputBuffer.takeAll()
                guard let self, let process, self.pty === process else { return }
                self.handleOutput(pending)
            }
        }
        process.onExit = { [weak self, weak process] code in
            DispatchQueue.main.async {
                guard let self, let process, self.pty === process else { return }
                // Keep the pty reference so buffered output that lands after
                // the exit notification (the two arrive on unordered queues)
                // still passes the identity guard and renders. Writes to the
                // now-exited process are no-ops inside PTYProcess. restart()
                // replaces the reference, which correctly drops stale output.
                self.status = .exited(code)
                self.onStatusChange?()
            }
        }

        let result = await Task.detached(priority: .userInitiated) { () -> LaunchResult in
            do {
                try process.launch()
                return .succeeded
            } catch let error as PTYProcess.LaunchError {
                return .failed(error.message)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        guard !Task.isCancelled,
              spawnGeneration == generation,
              pty === process else {
            // Restart/close won while posix_spawn was in flight. If launch did
            // succeed, tear down the stale child instead of orphaning it.
            if case .succeeded = result { process.terminate() }
            return
        }

        spawnTask = nil
        switch result {
        case .succeeded:
            // A custom shell can exit before the detached launch continuation
            // returns. Its onExit callback owns that terminal state; never
            // overwrite .exited with a stale .running transition or send an
            // initial command to a process that is already gone.
            if status == .starting, process.isRunning {
                status = .running
                // Feed the agent command to the shell. The PTY buffers it until the
                // shell finishes loading and reads stdin, so it runs at the prompt.
                if let initialCommand, !initialCommand.isEmpty {
                    process.write(Array((initialCommand + "\n").utf8))
                }
            }
        case .failed(let message):
            pty = nil
            status = .failed(message)
        }
        onStatusChange?()
    }

    // MARK: - Output

    private func handleOutput(_ bytes: [UInt8]) {
        logRawBytes(bytes)
        let actions = parser.parse(bytes)
        guard !actions.isEmpty else { return }
        for action in actions {
            screen.apply(action)
            if case .reportDeviceStatus(let code) = action {
                replyToDeviceStatus(code)
            }
        }
        onScreenUpdate?()
        if screen.title != lastNotifiedTitle {
            lastNotifiedTitle = screen.title
            onTitleChange?()
        }
    }

    // MARK: - Debug byte capture

    /// Opt-in Debug-only raw PTY capture for diagnosing render issues: set the
    /// environment variable FINDERPATH_TERMINAL_LOG=1 to append to
    /// ~/finderpath-terminal.log, or =<path> for a custom file. Release builds
    /// never capture terminal contents.
    #if DEBUG
    private static let debugLogURL: URL? = {
        guard let value = ProcessInfo.processInfo.environment["FINDERPATH_TERMINAL_LOG"],
              !value.isEmpty else { return nil }
        if value == "1" || value.lowercased() == "true" {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("finderpath-terminal.log")
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }()
    #else
    private static let debugLogURL: URL? = nil
    #endif
    private static let maximumDebugLogBytes: UInt64 = 5 * 1024 * 1024

    /// Appends the exact bytes handed to the parser as space-separated hex, one
    /// line per chunk. All failures are swallowed so logging never disrupts I/O.
    private func logRawBytes(_ bytes: [UInt8]) {
        guard let url = Self.debugLogURL, !bytes.isEmpty else { return }
        let line = bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let existingSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if existingSize + UInt64(data.count) > Self.maximumDebugLogBytes {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            _ = FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func replyToDeviceStatus(_ code: Int) {
        switch code {
        case 6:
            // CPR wants 1-based coordinates; the screen tracks 0-based.
            let reply = "\u{1B}[\(screen.cursorRow + 1);\(screen.cursorColumn + 1)R"
            pty?.write(Array(reply.utf8))
        case 5:
            pty?.write(Array("\u{1B}[0n".utf8))
        default:
            break
        }
    }

    // MARK: - Input

    func send(text: String, meta: Bool = false) {
        pty?.write(TerminalInputEncoder.encode(text: text, meta: meta))
    }

    func send(bytes: [UInt8]) {
        pty?.write(bytes)
    }

    func send(
        special: TerminalInputEncoder.SpecialKey,
        modifiers: TerminalInputEncoder.Modifiers = []
    ) {
        let bytes = TerminalInputEncoder.encode(
            specialKey: special,
            modifiers: modifiers,
            applicationCursorKeys: screen.applicationCursorKeys
        )
        pty?.write(bytes)
    }

    func paste(_ text: String) {
        pty?.write(TerminalInputEncoder.encodePaste(text, bracketed: screen.bracketedPaste))
    }

    func resize(rows: Int, columns: Int) {
        screen.resize(rows: rows, columns: columns)
        hasPreparedViewport = true
        if status == .notStarted, startWhenViewportIsReady {
            startWhenViewportIsReady = false
            spawn()
            return
        }
        pty?.resize(rows: rows, columns: columns)
    }
}

/// Coalesces PTY reads so a burst of output costs one main-queue hop instead
/// of one per 4 KB chunk. The read source delivers on a serial queue and the
/// drain runs on the serial main queue, so byte order is preserved end to end.
/// A noisy command must not allocate without bound while the UI is busy, but
/// terminal bytes form a protocol stream and cannot be dropped safely. The
/// producer therefore waits at the high-water mark until the scheduled drain
/// transfers ownership of the pending bytes and wakes it.
final class PTYOutputBuffer: @unchecked Sendable {
    static let maximumPendingBytes = 1_024 * 1_024
    private let condition = NSCondition()
    private var pending: [UInt8] = []
    private var drainScheduled = false

    var bufferedByteCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count
    }

    /// Appends bytes and reports whether the caller now owns scheduling the
    /// drain. Only one drain is ever outstanding, however fast output arrives.
    ///
    /// PTYProcess emits at most one 4 KB read per call, well below the one MiB
    /// bound. Waiting before the whole call fits keeps each read atomic and
    /// preserves byte order without ever exceeding the bound.
    func appendAndClaimDrain(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        precondition(
            bytes.count <= Self.maximumPendingBytes,
            "one PTY read must fit within the bounded output buffer"
        )

        condition.lock()
        defer { condition.unlock() }
        while pending.count > Self.maximumPendingBytes - bytes.count {
            // A nonempty buffer acquired the drain claim when its first bytes
            // arrived. The main-queue block always calls takeAll() before any
            // lifecycle identity guard, so even a replaced session wakes us.
            assert(drainScheduled)
            condition.wait()
        }

        pending.append(contentsOf: bytes)
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Hands over everything buffered, releases the drain claim, and wakes any
    /// producer waiting for enough room to append its complete PTY read.
    func takeAll() -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        var bytes: [UInt8] = []
        swap(&bytes, &pending)
        drainScheduled = false
        condition.broadcast()
        return bytes
    }
}
