import AppKit
import Darwin

// Installs an update archive in place and relaunches the app.
//
// Trust model: the downloaded bundle must pass strict code signing
// verification pinned to the FinderPath Developer ID team, plus a
// Gatekeeper assessment, before it replaces anything on disk. The
// download URL is never trusted on its own.
//
// Only `install`'s completion touches the main actor. Download, extraction,
// verification and replacement run on URLSession's background delegate
// queue, so the installer is nonisolated.
nonisolated enum UpdateInstaller {
    static let appBundleName = "FinderPath.app"
    static let expectedBundleID = "io.github.bhino50.FinderPath"
    static let expectedTeamID = "VJPMCBH6NX"
    private static let maximumArchiveSize: Int64 = 256 * 1_024 * 1_024
    private static let maximumExpandedSize: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumExpandedEntryCount = 50_000
    private static let maximumExpandedPathDepth = 64
    private static let extractionTimeout: TimeInterval = 120
    private static let commandTimeout: TimeInterval = 30
    private static let maximumCommandErrorBytes = 64 * 1_024
    private static let installationGate = InstallationGate()

    private final class InstallationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isInstalling = false

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isInstalling else { return false }
            isInstalling = true
            return true
        }

        func end() {
            lock.lock()
            isInstalling = false
            lock.unlock()
        }
    }

    /// Runs `body` only while no update is installing, so other work in the
    /// app folder cannot race a replacement or its rollback. Returns false,
    /// without running `body`, when an installation holds the gate.
    static func performExclusively(_ body: () -> Void) -> Bool {
        guard installationGate.begin() else { return false }
        defer { installationGate.end() }
        body()
        return true
    }

    enum BrowserRecoveryPolicy: Equatable {
        case unavailable
        case offerManifestDownload
    }

    enum InstallError: LocalizedError {
        case unsupportedHostBundle(String?)
        case noArchiveURL
        case downloadFailed(String)
        case downloadRejected(String)
        case extractionFailed(String)
        case appNotFoundInArchive
        case verificationFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedHostBundle:
                return "Automatic updates can only replace the official FinderPath app. Development builds remain isolated and must be rebuilt from source."
            case .noArchiveURL:
                return "This release does not include a direct install package."
            case .downloadFailed(let detail):
                return "The update could not be downloaded: \(detail)"
            case .downloadRejected(let detail):
                return "The update package was rejected: \(detail)"
            case .extractionFailed(let detail):
                return "The update package could not be opened: \(detail)"
            case .appNotFoundInArchive:
                return "The update package did not contain FinderPath.app."
            case .verificationFailed(let detail):
                return "The update failed security verification and was not installed: \(detail)"
            case .installFailed(let detail):
                return "The update could not be installed: \(detail)"
            }
        }

        /// Only a clearly operational download failure may offer the manifest's
        /// external download URL. Every package rejection and every error whose
        /// verification state is unknown fails closed.
        var browserRecoveryPolicy: BrowserRecoveryPolicy {
            switch self {
            case .downloadFailed:
                return .offerManifestDownload
            case .unsupportedHostBundle,
                 .noArchiveURL,
                 .downloadRejected,
                 .extractionFailed,
                 .appNotFoundInArchive,
                 .verificationFailed,
                 .installFailed:
                return .unavailable
            }
        }
    }

    static func install(
        manifest: UpdateManifest,
        completion: @escaping @MainActor (Result<Void, InstallError>) -> Void
    ) {
        let hostBundleIdentifier = Bundle.main.bundleIdentifier
        guard installerHostIsEligible(bundleIdentifier: hostBundleIdentifier) else {
            Task { @MainActor in
                completion(.failure(.unsupportedHostBundle(hostBundleIdentifier)))
            }
            return
        }
        guard let archiveURL = manifest.archiveURL else {
            Task { @MainActor in completion(.failure(.noArchiveURL)) }
            return
        }
        guard UpdateChecker.isHTTPSWebURL(archiveURL) else {
            Task { @MainActor in
                completion(.failure(.downloadRejected("Update packages must be served over HTTPS.")))
            }
            return
        }

        guard installationGate.begin() else {
            Task { @MainActor in
                completion(.failure(.installFailed("An update installation is already in progress.")))
            }
            return
        }
        let finish: @Sendable (Result<Void, InstallError>) -> Void = { result in
            installationGate.end()
            Task { @MainActor in completion(result) }
        }

        let workDir: URL
        do {
            workDir = try makeWorkDirectory()
        } catch {
            finish(.failure(.installFailed(error.localizedDescription)))
            return
        }
        let archiveFile = workDir.appendingPathComponent("update" + pathExtension(of: archiveURL))
        // Extraction, verification and replacement continue on the download
        // session's background delegate queue, never on the main actor.
        downloadArchive(from: archiveURL, to: archiveFile, maximumSize: maximumArchiveSize) { downloaded in
            defer { try? FileManager.default.removeItem(at: workDir) }
            do {
                let newApp = try extractApp(from: downloaded.get(), into: workDir)
                try verify(appAt: newApp, expectedVersion: manifest.latestVersion)
                try swapAndScheduleRelaunch(newApp: newApp, expectedVersion: manifest.latestVersion)
                finish(.success(()))
            } catch let error as InstallError {
                finish(.failure(error))
            } catch {
                finish(.failure(.installFailed(error.localizedDescription)))
            }
        }
    }

    /// Downloads an update package to `destination`, cancelling the transfer
    /// once it grows past `maximumSize`. No file remains after a failure.
    static func downloadArchive(
        from archiveURL: URL,
        to destination: URL,
        maximumSize: Int64,
        configuration: URLSessionConfiguration? = nil,
        completion: @escaping @Sendable (Result<URL, InstallError>) -> Void
    ) {
        // Ephemeral session for the same reason as UpdateChecker.check: no
        // persisted HTTP/3 mappings, so the download cannot stall on networks
        // that silently drop UDP 443 (QUIC).
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = commandTimeout
        configuration.timeoutIntervalForResource = 5 * 60
        SizeLimitedDownload.start(
            request: URLRequest(url: archiveURL),
            configuration: configuration,
            maximumSize: maximumSize,
            destination: destination
        ) { outcome in
            let result = validatedArchive(outcome, maximumSize: maximumSize)
            if case .failure = result { try? FileManager.default.removeItem(at: destination) }
            completion(result)
        }
    }

    private static func validatedArchive(
        _ outcome: SizeLimitedDownload.Outcome,
        maximumSize: Int64
    ) -> Result<URL, InstallError> {
        let sizeLimitMessage = "The update package exceeded the \(maximumSize / (1_024 * 1_024)) MB safety limit."
        if outcome.rejectedRedirect {
            return .failure(.downloadRejected("The update redirected to an unsafe location."))
        }
        // Cancelling an oversized transfer also reports an error; the limit
        // is the cause worth showing.
        if outcome.exceededLimit {
            return .failure(.downloadRejected(sizeLimitMessage))
        }
        if let error = outcome.error {
            return .failure(classifyDownloadError(error))
        }
        guard let httpResponse = outcome.response as? HTTPURLResponse else {
            return .failure(.downloadRejected("The update server returned an invalid response."))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            return .failure(.downloadRejected("Update server returned HTTP \(httpResponse.statusCode)."))
        }
        guard let finalURL = httpResponse.url, UpdateChecker.isHTTPSWebURL(finalURL) else {
            return .failure(.downloadRejected("The update redirected to a non-HTTPS location."))
        }
        if httpResponse.expectedContentLength > maximumSize {
            return .failure(.downloadRejected(sizeLimitMessage))
        }
        guard let archive = outcome.fileURL else {
            return .failure(.downloadRejected("No file was received."))
        }

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        guard archiveSize > 0 else {
            return .failure(.downloadRejected("The update package was empty."))
        }
        guard archiveSize <= maximumSize else {
            return .failure(.downloadRejected(sizeLimitMessage))
        }
        return .success(archive)
    }

    /// A Debug/no-Xcode bundle must never replace itself with a release bundle.
    /// Doing so crosses the development/production persistence namespace and
    /// defeats deterministic duplicate-process election on relaunch.
    static func installerHostIsEligible(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == expectedBundleID
    }

    /// URLSession uses the same error channel for ordinary connectivity loss
    /// and trust failures. Only explicit network-availability failures qualify
    /// for external browser recovery; unknown and security-sensitive failures
    /// remain rejected.
    static func classifyDownloadError(_ error: Error) -> InstallError {
        let detail = error.localizedDescription
        guard let urlError = error as? URLError else {
            return .downloadRejected(detail)
        }

        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return .downloadFailed(detail)
        default:
            return .downloadRejected(detail)
        }
    }

    // MARK: - Steps

    private static func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private static func pathExtension(of url: URL) -> String {
        url.pathExtension.lowercased() == "dmg" ? ".dmg" : ".zip"
    }

    static func extractApp(from archive: URL, into workDir: URL) throws -> URL {
        let extractDir = workDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(
            at: extractDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if archive.pathExtension.lowercased() == "dmg" {
            try extractFromDiskImage(archive, into: extractDir)
        } else {
            let result = run(
                "/usr/bin/ditto",
                ["-xk", archive.path, extractDir.path],
                timeout: extractionTimeout,
                expansionRoot: extractDir
            )
            guard result.status == 0 else {
                throw InstallError.extractionFailed(result.errorOutput)
            }
        }

        if let violation = expandedContentsViolation(at: extractDir) {
            throw InstallError.extractionFailed(violation)
        }

        guard let app = try findApp(in: extractDir) else {
            throw InstallError.appNotFoundInArchive
        }
        return app
    }

    private static func extractFromDiskImage(_ image: URL, into extractDir: URL) throws {
        let mountPoint = extractDir.deletingLastPathComponent()
            .appendingPathComponent("mount")
        var didDetach = false
        // Attach can mount the volume before its process times out or reports
        // a later error. Attempt cleanup on every exit path, including those
        // where attach did not return a successful status.
        defer {
            if !didDetach {
                _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], timeout: 15)
            }
        }
        let attach = run(
            "/usr/bin/hdiutil",
            [
                "attach", image.path,
                "-nobrowse", "-readonly", "-noautoopen",
                "-mountpoint", mountPoint.path
            ],
            timeout: 30,
            // A successful attach leaves a helper serving the mounted volume
            // after hdiutil exits. The detach calls here own its teardown.
            postExitDescendants: .preserve
        )
        guard attach.status == 0 else {
            throw InstallError.extractionFailed(attach.errorOutput)
        }
        guard let mountedApp = try findApp(in: mountPoint) else {
            throw InstallError.appNotFoundInArchive
        }
        let copied = extractDir.appendingPathComponent(mountedApp.lastPathComponent)
        let copy = run(
            "/usr/bin/ditto",
            [mountedApp.path, copied.path],
            timeout: extractionTimeout,
            expansionRoot: extractDir
        )
        guard copy.status == 0 else {
            throw InstallError.extractionFailed(copy.errorOutput)
        }
        let detach = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], timeout: 15)
        guard detach.status == 0 else {
            throw InstallError.extractionFailed("Could not detach the temporary update image: \(detach.errorOutput)")
        }
        didDetach = true
    }

    static func findApp(in directory: URL) throws -> URL? {
        var inspectionFailed = false
        guard let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                inspectionFailed = true
                return false
            }
        ) else {
            throw InstallError.extractionFailed("FinderPath could not inspect the update package.")
        }
        var entryCount = 0
        while let entry = contents.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= maximumExpandedEntryCount else {
                throw InstallError.extractionFailed(expandedEntryCountMessage(maximumEntries: maximumExpandedEntryCount))
            }
            guard entry.lastPathComponent == appBundleName else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw InstallError.extractionFailed("The package did not contain a real FinderPath app bundle.")
            }
            return entry
        }
        if inspectionFailed {
            throw InstallError.extractionFailed("FinderPath could not inspect the update package.")
        }
        return nil
    }

    private static func verify(appAt app: URL, expectedVersion: String) throws {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw InstallError.verificationFailed("The package did not contain a real FinderPath app bundle.")
        }

        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == expectedBundleID else {
            throw InstallError.verificationFailed("The package did not contain FinderPath with the expected bundle identifier.")
        }

        guard let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateChecker.versionsAreEquivalent(bundledVersion, expectedVersion) else {
            throw InstallError.verificationFailed("The app version did not match the release manifest.")
        }

        // Pin the signature to Apple's chain and the FinderPath team so a
        // compromised download location cannot ship a substitute binary.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        let signature = run("/usr/bin/codesign", [
            "--verify", "--strict", "--deep",
            "-R=\(requirement)",
            app.path
        ])
        guard signature.status == 0 else {
            throw InstallError.verificationFailed(signature.errorOutput)
        }

        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "exec", app.path])
        guard gatekeeper.status == 0 else {
            throw InstallError.verificationFailed(gatekeeper.errorOutput)
        }
    }

    private static func removeQuarantine(at app: URL) throws {
        // Safe only because verify(appAt:) ran first; this is what lets the
        // relaunch happen without a Gatekeeper first-open prompt.
        let result = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard result.status == 0 else {
            throw InstallError.installFailed("Could not prepare the verified app for launch: \(result.errorOutput)")
        }
    }

    private static func swapAndScheduleRelaunch(newApp: URL, expectedVersion: String) throws {
        _ = try stageAndReplaceApp(
            at: Bundle.main.bundleURL,
            with: newApp,
            prepareStagedApp: { source, stagedApp in
                let copy = run("/usr/bin/ditto", [source.path, stagedApp.path], timeout: extractionTimeout)
                guard copy.status == 0 else {
                    throw InstallError.installFailed(copy.errorOutput)
                }
                try verify(appAt: stagedApp, expectedVersion: expectedVersion)
                try removeQuarantine(at: stagedApp)
            },
            scheduleRelaunch: scheduleRelaunch
        )
    }

    @discardableResult
    static func stageAndReplaceApp(
        at target: URL,
        with newApp: URL,
        prepareStagedApp: (URL, URL) throws -> Void,
        scheduleRelaunch: (URL) throws -> Void
    ) throws -> URL {
        let parent = target.deletingLastPathComponent()
        let stagingDirectory = parent.appendingPathComponent(".FinderPathUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedApp = stagingDirectory.appendingPathComponent(appBundleName)
        // Finish and verify the entire copy on the destination volume before
        // moving the running app. Replacement then consists only of renames;
        // a slow or interrupted copy never exposes a partial installed bundle.
        try prepareStagedApp(newApp, stagedApp)
        return try replaceApp(at: target, with: stagedApp, scheduleRelaunch: scheduleRelaunch)
    }

    /// The transaction is testable with temporary fixture directories. Keep
    /// the previous bundle available for recovery because scheduling a launch
    /// is not proof that Launch Services or the new app started successfully.
    /// UpdateLeftoverCleanup moves it to the Trash after the next launch.
    @discardableResult
    static func replaceApp(
        at target: URL,
        with stagedApp: URL,
        scheduleRelaunch: (URL) throws -> Void
    ) throws -> URL {
        let retired = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).old-\(UUID().uuidString)"
        )

        do {
            try FileManager.default.moveItem(at: target, to: retired)
        } catch {
            throw InstallError.installFailed("Could not move the current app aside: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.moveItem(at: stagedApp, to: target)
        } catch {
            try restore(retiredApp: retired, to: target, after: error.localizedDescription)
            throw InstallError.installFailed(error.localizedDescription)
        }

        do {
            try scheduleRelaunch(target)
        } catch {
            try restore(retiredApp: retired, to: target, after: error.localizedDescription)
            throw error
        }

        return retired
    }

    private static func restore(retiredApp: URL, to target: URL, after failure: String) throws {
        // Preserve the complete replacement until restoration succeeds. If
        // the previous bundle is unavailable or its rename fails, deleting
        // the replacement first would leave the user without either app.
        guard FileManager.default.fileExists(atPath: retiredApp.path) else {
            throw InstallError.installFailed(
                "\(failure) The previous app could not be found at \(retiredApp.path); the replacement was retained at \(target.path)."
            )
        }
        let displaced = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).failed-\(UUID().uuidString)"
        )
        let hadReplacement = FileManager.default.fileExists(atPath: target.path)
        do {
            if hadReplacement { try FileManager.default.moveItem(at: target, to: displaced) }
            try FileManager.default.moveItem(at: retiredApp, to: target)
        } catch {
            if hadReplacement, !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: displaced, to: target)
            }
            throw InstallError.installFailed(
                "\(failure) The previous app also could not be restored: \(error.localizedDescription) Check the recovery bundle at \(retiredApp.path) and the replacement at \(target.path) or \(displaced.path)."
            )
        }
        if hadReplacement { try? FileManager.default.removeItem(at: displaced) }
    }

    private static func scheduleRelaunch(of app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = relaunchScript(of: app, processIdentifier: pid)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw InstallError.installFailed("Could not schedule FinderPath to relaunch: \(error.localizedDescription)")
        }
    }

    static func relaunchScript(
        of app: URL,
        processIdentifier: pid_t,
        maximumWaitAttempts: Int = 150
    ) -> String {
        let quotedPath = ShellCommand.argument(app.path, quoteStyle: "single")
        // Termination may be cancelled or a numeric PID may be reused. Either
        // case must expire the waiter instead of leaving a permanent helper.
        return """
        attempts=0
        while /bin/kill -0 \(processIdentifier) 2>/dev/null; do
          [ "$attempts" -lt \(max(maximumWaitAttempts, 0)) ] || exit 1
          attempts=$((attempts + 1))
          /bin/sleep 0.2
        done
        exec /usr/bin/open \(quotedPath)
        """
    }

    // MARK: - Process helper

    struct CommandResult {
        let status: Int32
        let errorOutput: String
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = commandTimeout,
        expansionRoot: URL? = nil,
        postExitDescendants: BoundedProcessRunner.PostExitDescendants = .terminate
    ) -> CommandResult {
        var nextExpansionCheck = Date()
        let monitored = BoundedProcessRunner.runMonitored(
            executable: executable,
            arguments: arguments,
            limits: .init(
                timeout: timeout,
                maximumStandardOutputBytes: 0,
                maximumStandardErrorBytes: maximumCommandErrorBytes
            ),
            postExitDescendants: postExitDescendants,
            stopReason: {
                guard let expansionRoot, Date() >= nextExpansionCheck else { return nil }
                nextExpansionCheck = Date().addingTimeInterval(0.25)
                return expandedContentsViolation(at: expansionRoot)
            }
        )
        let status: Int32
        let output: BoundedProcessRunner.CapturedOutput
        let failure: String?
        switch monitored {
        case .stopped(let reason, let captured):
            (status, output, failure) = (-1, captured, reason)
        case .completed(.exited(let exitStatus, let captured)):
            (status, output, failure) = (exitStatus, captured, nil)
        case .completed(.timedOut(let captured)):
            (status, output, failure) = (-1, captured, operationTimeoutMessage(seconds: timeout))
        case .completed(.executableNotFound(let path)):
            return CommandResult(status: -1, errorOutput: "The update tool is unavailable: \(path)")
        case .completed(.launchFailed(let message)):
            return CommandResult(status: -1, errorOutput: message)
        }
        let stderr = String(decoding: output.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [failure, stderr, output.standardErrorWasTruncated ? "Tool diagnostics were truncated." : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return CommandResult(status: status, errorOutput: detail)
    }

    static func operationTimeoutMessage(seconds: TimeInterval) -> String {
        "The update operation exceeded its \(Int(seconds))-second safety limit."
    }

    static func expandedEntryCountMessage(maximumEntries: Int) -> String {
        "The expanded update contained more than \(maximumEntries) entries."
    }

    static func expandedPathDepthMessage(maximumDepth: Int) -> String {
        "The expanded update exceeded the maximum path depth of \(maximumDepth)."
    }

    static func expandedSizeLimitMessage(maximumSize: Int64) -> String {
        "The expanded update exceeded the \(maximumSize / (1_024 * 1_024)) MB safety limit."
    }

    static let escapedContainmentMessage = "The expanded update contained an entry outside the package."
    static let unsupportedEntryMessage = "The expanded update contained an unsupported file type."

    private static func isContained(_ path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Symlinks are the entry class the extractor cannot make safe on its own:
    /// an absolute or climbing link inside the archive would let the install
    /// copy, or a later extracted entry, write outside the work tree. Links
    /// that stay inside the package (framework layouts) remain allowed.
    private static func symbolicLinkEscapes(_ link: URL, root: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return true
        }
        if destination.hasPrefix("/") { return true }
        let resolved = link.deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
        return !isContained(resolved.path, within: root.standardizedFileURL.path)
    }

    /// Returns a user-facing reason when extracted contents exceed a resource
    /// ceiling. Kept internal so the release logic tests can exercise the
    /// archive-bomb guard without installing an app.
    private static func expandedContentsViolation(at root: URL) -> String? {
        expandedContentsViolation(
            at: root,
            maximumSize: maximumExpandedSize,
            maximumEntries: maximumExpandedEntryCount,
            maximumDepth: maximumExpandedPathDepth
        )
    }

    static func expandedContentsViolation(
        at root: URL,
        maximumSize: Int64,
        maximumEntries: Int,
        maximumDepth: Int
    ) -> String? {
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            return "FinderPath could not inspect the expanded update."
        }
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            return "FinderPath could not inspect the expanded update."
        }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        var entryCount = 0
        var totalSize: Int64 = 0
        while let entry = enumerator.nextObject() as? URL {
            entryCount += 1
            if entryCount > maximumEntries {
                return expandedEntryCountMessage(maximumEntries: maximumEntries)
            }

            let depth = entry.standardizedFileURL.pathComponents.count - rootDepth
            if depth > maximumDepth {
                return expandedPathDepthMessage(maximumDepth: maximumDepth)
            }

            let values: URLResourceValues
            do {
                values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey]
                )
            } catch {
                return "FinderPath could not inspect the expanded update."
            }
            // Zip-slip defense in depth: the archive is inspected before any
            // signature check, so a link that resolves outside the extraction
            // root is rejected here, before verification or install follow it.
            if values.isSymbolicLink == true {
                if symbolicLinkEscapes(entry, root: root) {
                    return escapedContainmentMessage
                }
                continue
            }
            guard values.isDirectory != true else { continue }
            guard values.isRegularFile == true else { return unsupportedEntryMessage }
            guard let size = values.fileSize, size >= 0 else {
                return "FinderPath could not inspect the expanded update."
            }
            let fileSize = Int64(size)
            let (newTotal, overflow) = totalSize.addingReportingOverflow(fileSize)
            if overflow || newTotal > maximumSize {
                return expandedSizeLimitMessage(maximumSize: maximumSize)
            }
            totalSize = newTotal
        }
        if enumerationFailed {
            return "FinderPath could not inspect the expanded update."
        }
        return nil
    }
}
