import Foundation

/// One remembered Finder folder. Only the path and the moment it was last seen
/// are stored; nothing about the folder's contents reaches disk.
struct RecentPath: Codable, Equatable {
    let path: String
    var lastVisited: Date
}

/// Pure list and codec logic. Kept nonisolated so the synchronous logic-test
/// runner can exercise it without actor hops, the same split
/// TerminalSessionStore uses for its metadata codec.
nonisolated enum RecentPathsLogic {
    /// Long enough to cover a working session, short enough that the submenu
    /// stays scannable at a glance.
    static let limit = 10

    /// Returns a new list with `path` at the front. Revisiting a folder promotes
    /// its existing entry rather than duplicating it, and the result is capped so
    /// the history can never grow without bound.
    ///
    /// Only absolute paths are accepted. That single check also rejects the
    /// empty string and every "Finder AppleScript error: ..." message, so an
    /// error can never be recorded as though it were a folder.
    static func recording(
        _ path: String,
        into list: [RecentPath],
        at date: Date,
        limit: Int = limit
    ) -> [RecentPath] {
        // Do not trim the path: spaces and newlines are legal filename bytes.
        // Absolute-path validation is enough to reject empty strings and every
        // Finder error message without rewriting a real folder name.
        guard path.hasPrefix("/") else { return list }

        let key = standardized(path)
        let remaining = list.filter { standardized($0.path) != key }
        let updated = [RecentPath(path: key, lastVisited: date)] + remaining
        return Array(updated.prefix(max(0, limit)))
    }

    /// Menu titles are the folder name alone, which is ambiguous when two entries
    /// share it — two checkouts each containing "src". Any name appearing more
    /// than once gains its parent component on every occurrence, so the
    /// disambiguation is symmetric rather than singling one entry out.
    static func menuTitles(for list: [RecentPath]) -> [String] {
        let leaves = list.map(leafName(for:))
        var occurrences: [String: Int] = [:]
        for leaf in leaves {
            occurrences[leaf, default: 0] += 1
        }

        return zip(list, leaves).map { entry, leaf in
            guard (occurrences[leaf] ?? 0) > 1 else { return leaf }
            let parent = URL(fileURLWithPath: entry.path)
                .deletingLastPathComponent()
                .lastPathComponent
            return parent.isEmpty ? leaf : "\(parent)/\(leaf)"
        }
    }

    /// Corrupt or truncated data yields an empty list: a damaged history file
    /// must never crash or block app launch.
    static func decode(_ data: Data) -> [RecentPath] {
        guard !data.isEmpty else { return [] }
        do {
            let decoded = try JSONDecoder().decode([RecentPath].self, from: data)
            var seen = Set<String>()
            var sanitized: [RecentPath] = []
            for entry in decoded where entry.path.hasPrefix("/") {
                let path = standardized(entry.path)
                guard seen.insert(path).inserted else { continue }
                sanitized.append(RecentPath(path: path, lastVisited: entry.lastVisited))
                if sanitized.count == limit { break }
            }
            return sanitized
        } catch {
            NSLog("RecentPathsStore: ignoring unreadable history: %@", error.localizedDescription)
            return []
        }
    }

    static func encode(_ list: [RecentPath]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// Trailing slashes and relative components must not produce a second entry
    /// for a folder already in the list.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func leafName(for entry: RecentPath) -> String {
        let name = URL(fileURLWithPath: entry.path).lastPathComponent
        return name.isEmpty ? entry.path : name
    }
}

/// Ordered history of the folders FinderPath has seen, persisted as JSON beside
/// the terminal session metadata and with the same permission hardening.
@MainActor
final class RecentPathsStore {
    static let shared = RecentPathsStore()

    private(set) var paths: [RecentPath] = []

    func record(_ path: String) {
        let updated = RecentPathsLogic.recording(path, into: paths, at: Date())
        // Reopening the menu in the folder already at the front moves only the
        // timestamp. Persisting that would mean a disk write on every single
        // menu click, so the file is rewritten only when the order changes.
        let orderChanged = updated.map(\.path) != paths.map(\.path)
        paths = updated
        guard orderChanged else { return }
        persist()
    }

    func clear() {
        guard !paths.isEmpty else { return }
        paths = []
        persist()
    }

    func load() {
        let url = Self.persistenceURL()
        // Upgrade permissions before reading so a file written by an older build
        // stops exposing folder names to other local accounts right away, rather
        // than whenever the list next happens to change.
        try? Self.hardenPermissions(at: url)
        guard let data = try? Data(contentsOf: url) else { return }
        paths = RecentPathsLogic.decode(data)
    }

    func persist() {
        let url = Self.persistenceURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try RecentPathsLogic.encode(paths).write(to: url, options: .atomic)
            try Self.hardenPermissions(at: url)
        } catch {
            // A history that cannot be saved must never take the app down.
            NSLog("RecentPathsStore: failed to persist history: %@", error.localizedDescription)
        }
    }

    nonisolated static func applicationSupportDirectoryName(bundleIdentifier: String?) -> String {
        bundleIdentifier == "io.github.bhino50.FinderPathDev" ? "FinderPathDev" : "FinderPath"
    }

    private nonisolated static func persistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(
                applicationSupportDirectoryName(bundleIdentifier: Bundle.main.bundleIdentifier),
                isDirectory: true
            )
            .appendingPathComponent("recent-paths.json")
    }

    private nonisolated static func hardenPermissions(at url: URL) throws {
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
}
