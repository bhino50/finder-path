import Foundation

// Ordered list of terminal sessions plus JSON persistence of their metadata
// (id, name, working directory). Scrollback contents are deliberately never
// written to disk. The codec is nonisolated so the synchronous test runner
// can exercise it without actor hops.

/// The only session state that survives a relaunch. Restored sessions come
/// back as .notStarted and respawn lazily on first view.
struct TerminalSessionMetadata: Codable, Equatable {
    let id: UUID
    var name: String
    var workingDirectory: String
}

/// Spawn settings the app layer supplies from user preferences. Kept as a
/// value type injected through the store so the store itself never depends on
/// the AppKit preferences layer and stays exercisable by the logic tests.
struct TerminalSessionConfiguration {
    var shellPath: String
    var scrollbackLimit: Int

    init(shellPath: String = PTYProcess.defaultShell(), scrollbackLimit: Int = 2000) {
        self.shellPath = shellPath
        self.scrollbackLimit = scrollbackLimit
    }
}

@MainActor
final class TerminalSessionStore {
    static let shared = TerminalSessionStore()

    private(set) var sessions: [TerminalSession] = []
    var onChange: (() -> Void)?

    /// Resolves the current shell and scrollback settings at session-creation
    /// time. The app installs a preferences-backed provider at launch; the
    /// default keeps the store usable (and testable) on its own.
    var configurationProvider: () -> TerminalSessionConfiguration = { TerminalSessionConfiguration() }

    // MARK: - Session management

    func newSession(name: String?, workingDirectory: String, initialCommand: String? = nil) -> TerminalSession {
        let configuration = configurationProvider()
        let session = TerminalSession(
            name: name ?? nextAutoName(),
            workingDirectory: workingDirectory,
            shellPath: configuration.shellPath,
            scrollbackLimit: configuration.scrollbackLimit,
            initialCommand: initialCommand
        )
        sessions.append(session)
        persist()
        onChange?()
        return session
    }

    func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        sessions.remove(at: index)
        persist()
        onChange?()
    }

    /// Renames are metadata changes, so they persist immediately instead of
    /// waiting for the next add or remove.
    func rename(_ session: TerminalSession, to newName: String) {
        guard session.name != newName else { return }
        session.name = newName
        // A manual rename pins the label so the shell title stops overriding it.
        session.hasCustomName = true
        persist()
        onChange?()
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    /// Smallest free N keeps names compact after removals: with Terminal 1
    /// and Terminal 3 stored, the next session becomes Terminal 2.
    private func nextAutoName() -> String {
        let existingNames = Set(sessions.map(\.name))
        var candidate = 1
        while existingNames.contains("Terminal \(candidate)") {
            candidate += 1
        }
        return "Terminal \(candidate)"
    }

    // MARK: - Persistence

    func loadPersistedSessions() {
        guard let data = try? Data(contentsOf: Self.persistenceURL()) else { return }
        let metadata = Self.decodeMetadata(data)
        guard !metadata.isEmpty else { return }
        let configuration = configurationProvider()
        sessions = metadata.map { entry in
            TerminalSession(
                id: entry.id,
                name: entry.name,
                workingDirectory: entry.workingDirectory,
                shellPath: configuration.shellPath,
                scrollbackLimit: configuration.scrollbackLimit
            )
        }
        onChange?()
    }

    func persist() {
        let metadata = sessions.map { session in
            TerminalSessionMetadata(
                id: session.id,
                name: session.name,
                workingDirectory: session.workingDirectory
            )
        }
        let url = Self.persistenceURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encodeMetadata(metadata).write(to: url, options: .atomic)
        } catch {
            // Persistence failure must never take sessions down with it.
            NSLog("TerminalSessionStore: failed to persist sessions: %@", error.localizedDescription)
        }
    }

    private nonisolated static func persistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FinderPath/terminal-sessions.json")
    }

    // MARK: - Metadata codec (pure, tested)

    /// Corrupt or empty data yields an empty list: a damaged file must never
    /// crash or block app launch.
    nonisolated static func decodeMetadata(_ data: Data) -> [TerminalSessionMetadata] {
        do {
            return try JSONDecoder().decode([TerminalSessionMetadata].self, from: data)
        } catch {
            NSLog("TerminalSessionStore: ignoring unreadable session metadata: %@", error.localizedDescription)
            return []
        }
    }

    nonisolated static func encodeMetadata(_ list: [TerminalSessionMetadata]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }
}
