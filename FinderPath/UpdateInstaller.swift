import AppKit
import Darwin
import os

// Installs an update archive in place and relaunches the app.
//
// Trust model: the downloaded bundle must pass strict code signing
// verification pinned to the FinderPath Developer ID team, plus a
// Gatekeeper assessment, before it replaces anything on disk. The
// download URL is never trusted on its own.
enum UpdateInstaller {
    static let appBundleName = "FinderPath.app"
    static let expectedBundleID = "io.github.bhino50.FinderPath"
    static let expectedTeamID = "VJPMCBH6NX"
    private static let maximumArchiveSize: Int64 = 256 * 1_024 * 1_024
    private static let maximumExpandedSize: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumExpandedEntryCount = 50_000
    private static let maximumExpandedPathDepth = 64
    private static let extractionTimeout: TimeInterval = 120

    enum BrowserRecoveryPolicy: Equatable {
        case unavailable
        case offerManifestDownload
    }

    /// Cancels an oversized update while bytes are still arriving. The final
    /// file-size check remains as a second line of defense for responses whose
    /// expected length is unknown or inaccurate.
    private final class DownloadSizeLimiter: NSObject, URLSessionDownloadDelegate {
        private let maximumSize: Int64
        private let lock = NSLock()
        private var exceeded = false

        init(maximumSize: Int64) {
            self.maximumSize = maximumSize
        }

        var didExceedLimit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let knownLengthIsTooLarge = totalBytesExpectedToWrite > maximumSize
            guard totalBytesWritten > maximumSize || knownLengthIsTooLarge else { return }
            lock.lock()
            exceeded = true
            lock.unlock()
            downloadTask.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
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
        guard isHTTPSWebURL(archiveURL) else {
            Task { @MainActor in
                completion(.failure(.downloadRejected("Update packages must be served over HTTPS.")))
            }
            return
        }

        let finish: (Result<Void, InstallError>) -> Void = { result in
            Task { @MainActor in completion(result) }
        }

        // Ephemeral session for the same reason as UpdateChecker.check: no
        // persisted HTTP/3 mappings, so the download cannot stall on networks
        // that silently drop UDP 443 (QUIC).
        let sizeLimiter = DownloadSizeLimiter(maximumSize: maximumArchiveSize)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: sizeLimiter,
            delegateQueue: nil
        )
        session.downloadTask(with: archiveURL) { location, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                if sizeLimiter.didExceedLimit {
                    finish(.failure(.downloadRejected("The update package exceeded the 256 MB safety limit.")))
                    return
                }
                finish(.failure(classifyDownloadError(error)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                finish(.failure(.downloadRejected("The update server returned an invalid response.")))
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                finish(.failure(.downloadRejected("Update server returned HTTP \(httpResponse.statusCode).")))
                return
            }
            guard let finalURL = httpResponse.url, isHTTPSWebURL(finalURL) else {
                finish(.failure(.downloadRejected("The update redirected to a non-HTTPS location.")))
                return
            }
            if httpResponse.expectedContentLength > maximumArchiveSize {
                finish(.failure(.downloadRejected("The update package exceeded the 256 MB safety limit.")))
                return
            }
            guard let location else {
                finish(.failure(.downloadRejected("No file was received.")))
                return
            }

            let archiveSize = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            guard archiveSize > 0 else {
                finish(.failure(.downloadRejected("The update package was empty.")))
                return
            }
            guard archiveSize <= maximumArchiveSize else {
                finish(.failure(.downloadRejected("The update package exceeded the 256 MB safety limit.")))
                return
            }

            do {
                let workDir = try makeWorkDirectory()
                defer { try? FileManager.default.removeItem(at: workDir) }

                let archiveFile = workDir.appendingPathComponent("update" + pathExtension(of: archiveURL))
                try FileManager.default.moveItem(at: location, to: archiveFile)

                let newApp = try extractApp(from: archiveFile, into: workDir)
                try verify(appAt: newApp, expectedVersion: manifest.latestVersion)
                try removeQuarantine(at: newApp)
                try swapAndScheduleRelaunch(newApp: newApp)
                finish(.success(()))
            } catch let error as InstallError {
                finish(.failure(error))
            } catch {
                finish(.failure(.installFailed(error.localizedDescription)))
            }
        }.resume()
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

    private static func extractApp(from archive: URL, into workDir: URL) throws -> URL {
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
        let attach = run(
            "/usr/bin/hdiutil",
            [
                "attach", image.path,
                "-nobrowse", "-readonly", "-noautoopen",
                "-mountpoint", mountPoint.path
            ],
            timeout: 30
        )
        guard attach.status == 0 else {
            throw InstallError.extractionFailed(attach.errorOutput)
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

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
    }

    private static func findApp(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.first { $0.lastPathComponent == appBundleName }
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

    private static func swapAndScheduleRelaunch(newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        let retired = parent.appendingPathComponent(".\(target.lastPathComponent).old-\(ProcessInfo.processInfo.processIdentifier)")

        do {
            try FileManager.default.moveItem(at: target, to: retired)
        } catch {
            throw InstallError.installFailed("Could not move the current app aside: \(error.localizedDescription)")
        }

        let copy = run("/usr/bin/ditto", [newApp.path, target.path])
        guard copy.status == 0 else {
            // Roll the old version back so the user is never left without an app.
            try restore(retiredApp: retired, to: target, after: copy.errorOutput)
            throw InstallError.installFailed(copy.errorOutput)
        }

        do {
            try scheduleRelaunch(of: target)
        } catch {
            try restore(retiredApp: retired, to: target, after: error.localizedDescription)
            throw error
        }

        try? FileManager.default.removeItem(at: retired)
    }

    private static func restore(retiredApp: URL, to target: URL, after failure: String) throws {
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: retiredApp, to: target)
        } catch {
            throw InstallError.installFailed(
                "\(failure) The previous app also could not be restored: \(error.localizedDescription)"
            )
        }
    }

    private static func scheduleRelaunch(of app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedPath = ShellCommand.argument(app.path, quoteStyle: "single")
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quotedPath)"

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

    // MARK: - Process helper

    private static func isHTTPSWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    private struct CommandResult {
        let status: Int32
        let errorOutput: String
    }

    private static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        expansionRoot: URL? = nil
    ) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let errorPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            return CommandResult(status: -1, errorOutput: error.localizedDescription)
        }

        // Drain stderr while the child runs. A command that fills the pipe must
        // not deadlock before the timeout or expansion monitor can stop it.
        let reads = DispatchGroup()
        let errorData = OSAllocatedUnfairLock(initialState: Data())
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
            reads.leave()
        }

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var nextExpansionCheck = Date()
        var monitorFailure: String?
        while task.isRunning {
            let now = Date()
            if let deadline, now >= deadline {
                monitorFailure = operationTimeoutMessage(seconds: timeout ?? 0)
                stop(task)
                break
            }
            if let expansionRoot, now >= nextExpansionCheck {
                if let violation = expandedContentsViolation(at: expansionRoot) {
                    monitorFailure = violation
                    stop(task)
                    break
                }
                nextExpansionCheck = now.addingTimeInterval(0.25)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        task.waitUntilExit()
        reads.wait()
        let stderr = String(data: errorData.withLock { $0 }, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = [monitorFailure, stderr]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return CommandResult(status: task.terminationStatus, errorOutput: detail)
    }

    private static func stop(_ task: Process) {
        guard task.isRunning else { return }
        task.terminate()
        let graceDeadline = Date().addingTimeInterval(1)
        while task.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            Darwin.kill(task.processIdentifier, SIGKILL)
        }
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
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
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
                values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
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
            let fileSize = Int64(max(values.fileSize ?? 0, 0))
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
