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

    private(set) var status: Status = .notStarted
    private(set) var screen: TerminalScreen

    var onScreenUpdate: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private let shellPath: String
    private let scrollbackLimit: Int
    private var pty: PTYProcess?
    private var parser = TerminalParser()

    init(
        id: UUID = UUID(),
        name: String,
        workingDirectory: String,
        shellPath: String = PTYProcess.defaultShell(),
        scrollbackLimit: Int = 2000
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
        self.scrollbackLimit = scrollbackLimit
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
        spawn()
    }

    func restart() {
        pty?.terminate()
        pty = nil
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
            Task { @MainActor in
                guard let self, let process, self.pty === process else { return }
                self.handleOutput(bytes)
            }
        }
        process.onExit = { [weak self, weak process] code in
            Task { @MainActor in
                guard let self, let process, self.pty === process else { return }
                self.pty = nil
                self.status = .exited(code)
                self.onStatusChange?()
            }
        }

        do {
            try process.launch()
            pty = process
            status = .running
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
        let actions = parser.parse(bytes)
        guard !actions.isEmpty else { return }
        for action in actions {
            screen.apply(action)
            if case .reportDeviceStatus(let code) = action {
                replyToDeviceStatus(code)
            }
        }
        onScreenUpdate?()
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

    func send(text: String) {
        pty?.write(TerminalInputEncoder.encode(text: text))
    }

    func send(special: TerminalInputEncoder.SpecialKey) {
        let bytes = TerminalInputEncoder.encode(
            specialKey: special,
            applicationCursorKeys: screen.applicationCursorKeys
        )
        pty?.write(bytes)
    }

    func paste(_ text: String) {
        pty?.write(TerminalInputEncoder.encodePaste(text, bracketed: screen.bracketedPaste))
    }

    func resize(rows: Int, columns: Int) {
        screen.resize(rows: rows, columns: columns)
        pty?.resize(rows: rows, columns: columns)
    }
}
