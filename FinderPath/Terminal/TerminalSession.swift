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
        pty?.terminate()
        pty = nil
        startWhenViewportIsReady = false
        parser = TerminalParser()
        screen = TerminalScreen(
            rows: screen.rows,
            columns: screen.columns,
            scrollbackLimit: scrollbackLimit
        )
        onScreenUpdate?()
        spawn()
    }

    func terminate() {
        // Status flips to .exited via the onExit callback so the exit code
        // shown in the UI is the real one, not a guess made here.
        pty?.terminate()
    }

    private func spawn() {
        let process = PTYProcess(
            executable: shellPath,
            arguments: ["-l"],
            workingDirectory: resolvedWorkingDirectory(),
            environment: [:],
            rows: screen.rows,
            columns: screen.columns
        )

        // Identity checks drop late output or exits from a process that has
        // been replaced by restart(); without them a stale exit callback
        // could mark a freshly restarted session as dead.
        process.onOutput = { [weak self, weak process] bytes in
            // PTY output is produced on one serial read queue. Dispatching that
            // queue directly onto the serial main queue preserves byte-chunk
            // order; separate unstructured Tasks may execute out of order and
            // split zsh's erase/cursor/redraw sequences during history recall
            // or a SIGWINCH resize burst.
            DispatchQueue.main.async {
                guard let self, let process, self.pty === process else { return }
                self.handleOutput(bytes)
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

        do {
            try process.launch()
            pty = process
            status = .running
            // Feed the agent command to the shell. The PTY buffers it until the
            // shell finishes loading and reads stdin, so it runs at the prompt.
            if let initialCommand, !initialCommand.isEmpty {
                process.write(Array((initialCommand + "\n").utf8))
            }
        } catch let error as PTYProcess.LaunchError {
            pty = nil
            status = .failed(error.message)
        } catch {
            pty = nil
            status = .failed(error.localizedDescription)
        }
        onStatusChange?()
    }

    /// A persisted directory can vanish between launches; falling back to
    /// home keeps the shell spawnable instead of failing on chdir.
    private func resolvedWorkingDirectory() -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return workingDirectory
        }
        return NSHomeDirectory()
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
