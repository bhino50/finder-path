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
    /// A user rename pins the tab label against later OSC shell-title updates.
    /// Decode missing values as false so metadata from FinderPath 1.6 remains valid.
    var hasCustomName: Bool

    init(id: UUID, name: String, workingDirectory: String, hasCustomName: Bool = false) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.hasCustomName = hasCustomName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case workingDirectory
        case hasCustomName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        hasCustomName = try container.decodeIfPresent(Bool.self, forKey: .hasCustomName) ?? false
    }
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
        let url = Self.persistenceURL()
        // Upgrade permissions before decoding so an empty or corrupt legacy
        // file cannot keep exposing working-directory metadata to other local
        // accounts until the user happens to add or remove a session.
        try? Self.hardenPersistencePermissions(at: url)
        guard let data = try? Data(contentsOf: url) else { return }
        let metadata = Self.decodeMetadata(data)
        guard !metadata.isEmpty else { return }
        let configuration = configurationProvider()
        sessions = metadata.map { entry in
            let session = TerminalSession(
                id: entry.id,
                name: entry.name,
                workingDirectory: entry.workingDirectory,
                shellPath: configuration.shellPath,
                scrollbackLimit: configuration.scrollbackLimit
            )
            session.hasCustomName = entry.hasCustomName
            return session
        }
        onChange?()
    }

    func persist() {
        let metadata = sessions.map { session in
            TerminalSessionMetadata(
                id: session.id,
                name: session.name,
                workingDirectory: session.workingDirectory,
                hasCustomName: session.hasCustomName
            )
        }
        let url = Self.persistenceURL()
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.encodeMetadata(metadata).write(to: url, options: .atomic)
            try Self.hardenPersistencePermissions(at: url)
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

    private nonisolated static func hardenPersistencePermissions(at url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
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
