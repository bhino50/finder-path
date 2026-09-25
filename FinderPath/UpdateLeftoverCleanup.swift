import AppKit
import Darwin

/// Moves bundles retired by earlier in-app updates to the Trash once a newer
/// FinderPath has launched from the same folder. UpdateInstaller keeps the
/// previous bundle until then because scheduling a relaunch does not prove the
/// new app starts. A leftover is kept unless every check shows it is an
/// updater-named, user-owned FinderPath bundle no newer than the running app.
nonisolated enum UpdateLeftoverCleanup {
    private static let retiredNamePrefix = ".\(UpdateInstaller.appBundleName).old-"
    private static let uuidStringLength = 36
    private static let maximumCandidatesExamined = 64
    private static let maximumTrashedPerLaunch = 8
    private static let maximumInfoPlistBytes: off_t = 1_024 * 1_024
    /// Waits until the new version has launched and stayed up.
    private static let launchSettleNanoseconds: UInt64 = 30_000_000_000

    /// Schedules one cleanup pass after launch has settled. Development
    /// builds never clean the folder they run from.
    @MainActor
    static func scheduleAfterLaunch() {
        guard Bundle.main.bundleIdentifier == UpdateInstaller.expectedBundleID else { return }
        let runningApp = Bundle.main.bundleURL
        let runningVersion = AppVersion.shortVersionString
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: launchSettleNanoseconds)
            let runningBundlePaths = Set(NSWorkspace.shared.runningApplications.compactMap {
                $0.bundleURL?.standardizedFileURL.path
            })
            Task.detached(priority: .utility) {
                run(
                    runningApp: runningApp,
                    runningBundleIdentifier: UpdateInstaller.expectedBundleID,
                    runningVersion: runningVersion,
                    runningBundlePaths: runningBundlePaths
                )
            }
        }
    }

    /// Returns the names moved to the Trash. Does nothing while an update is
    /// installing, because that installation may still need its retired copy.
    @discardableResult
    static func run(
        runningApp: URL,
        runningBundleIdentifier: String?,
        runningVersion: String,
        runningBundlePaths: Set<String>,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [String] {
        guard runningBundleIdentifier == UpdateInstaller.expectedBundleID,
              runningApp.lastPathComponent == UpdateInstaller.appBundleName else { return [] }
        let folder = runningApp.deletingLastPathComponent()
        var trashed: [String] = []
        _ = UpdateInstaller.performExclusively {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.filter(isRetiredBundleName).prefix(maximumCandidatesExamined) {
                guard trashed.count < maximumTrashedPerLaunch else { break }
                let candidate = folder.appendingPathComponent(name)
                guard !runningBundlePaths.contains(candidate.standardizedFileURL.path),
                      isRetiredFinderPath(candidate, notNewerThan: runningVersion) else { continue }
                do {
                    try trash(candidate)
                    trashed.append(name)
                } catch {
                    NSLog("FinderPath: kept retired update bundle %@: %@", candidate.path, error.localizedDescription)
                }
            }
        }
        return trashed
    }

    /// Exactly the name UpdateInstaller.replaceApp gives a retired bundle.
    /// Either UUID letter case is accepted.
    private static func isRetiredBundleName(_ name: String) -> Bool {
        guard name.hasPrefix(retiredNamePrefix) else { return false }
        let suffix = name.dropFirst(retiredNamePrefix.count)
        return suffix.count == uuidStringLength && UUID(uuidString: String(suffix)) != nil
    }

    private static func isRetiredFinderPath(_ bundle: URL, notNewerThan runningVersion: String) -> Bool {
        let infoPlist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let bundleInfo = ownedEntry(at: bundle), bundleInfo.st_mode & S_IFMT == S_IFDIR,
              let contentsInfo = ownedEntry(at: bundle.appendingPathComponent("Contents")),
              contentsInfo.st_mode & S_IFMT == S_IFDIR,
              let plistInfo = ownedEntry(at: infoPlist), plistInfo.st_mode & S_IFMT == S_IFREG,
              plistInfo.st_size <= maximumInfoPlistBytes,
              let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == UpdateInstaller.expectedBundleID,
              let version = info["CFBundleShortVersionString"] as? String else { return false }
        return UpdateChecker.versionsAreEquivalent(version, runningVersion)
            || UpdateChecker.compare(runningVersion, isNewerThan: version)
    }

    /// `lstat` never follows a symbolic link, so a link is never mistaken
    /// for the directory or file it points to.
    private static func ownedEntry(at url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() else { return nil }
        return info
    }
}
