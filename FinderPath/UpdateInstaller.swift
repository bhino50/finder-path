import AppKit

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

    enum InstallError: LocalizedError {
        case noArchiveURL
        case downloadFailed(String)
        case extractionFailed(String)
        case appNotFoundInArchive
        case verificationFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .noArchiveURL:
                return "This release does not include a direct install package."
            case .downloadFailed(let detail):
                return "The update could not be downloaded: \(detail)"
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
    }

    static func install(
        manifest: UpdateManifest,
        completion: @escaping @MainActor (Result<Void, InstallError>) -> Void
    ) {
        guard let archiveURL = manifest.archiveURL else {
            Task { @MainActor in completion(.failure(.noArchiveURL)) }
            return
        }
        guard isHTTPSWebURL(archiveURL) else {
            Task { @MainActor in
                completion(.failure(.downloadFailed("Update packages must be served over HTTPS.")))
            }
            return
        }

        let finish: (Result<Void, InstallError>) -> Void = { result in
            Task { @MainActor in completion(result) }
        }

        // Ephemeral session for the same reason as UpdateChecker.check: no
        // persisted HTTP/3 mappings, so the download cannot stall on networks
        // that silently drop UDP 443 (QUIC).
        let session = URLSession(configuration: .ephemeral)
        session.downloadTask(with: archiveURL) { location, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                finish(.failure(.downloadFailed(error.localizedDescription)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
                let detail = status.map { "Update server returned HTTP \($0)." }
                    ?? "The update server returned an invalid response."
                finish(.failure(.downloadFailed(detail)))
                return
            }
            guard let finalURL = httpResponse.url, isHTTPSWebURL(finalURL) else {
                finish(.failure(.downloadFailed("The update redirected to a non-HTTPS location.")))
                return
            }
            guard let location else {
                finish(.failure(.downloadFailed("No file was received.")))
                return
            }

            let archiveSize = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            guard archiveSize > 0 else {
                finish(.failure(.downloadFailed("The update package was empty.")))
                return
            }
            guard archiveSize <= maximumArchiveSize else {
                finish(.failure(.downloadFailed("The update package exceeded the 256 MB safety limit.")))
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

    // MARK: - Steps

    private static func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func pathExtension(of url: URL) -> String {
        url.pathExtension.lowercased() == "dmg" ? ".dmg" : ".zip"
    }

    private static func extractApp(from archive: URL, into workDir: URL) throws -> URL {
        let extractDir = workDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        if archive.pathExtension.lowercased() == "dmg" {
            try extractFromDiskImage(archive, into: extractDir)
        } else {
            let result = run("/usr/bin/ditto", ["-xk", archive.path, extractDir.path])
            guard result.status == 0 else {
                throw InstallError.extractionFailed(result.errorOutput)
            }
        }

        guard let app = try findApp(in: extractDir) else {
            throw InstallError.appNotFoundInArchive
        }
        return app
    }

    private static func extractFromDiskImage(_ image: URL, into extractDir: URL) throws {
        let mountPoint = extractDir.deletingLastPathComponent()
            .appendingPathComponent("mount")
        let attach = run("/usr/bin/hdiutil", [
            "attach", image.path,
            "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountPoint.path
        ])
        guard attach.status == 0 else {
            throw InstallError.extractionFailed(attach.errorOutput)
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        guard let mountedApp = try findApp(in: mountPoint) else {
            throw InstallError.appNotFoundInArchive
        }
        let copied = extractDir.appendingPathComponent(mountedApp.lastPathComponent)
        let copy = run("/usr/bin/ditto", [mountedApp.path, copied.path])
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

    private static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
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

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandResult(status: task.terminationStatus, errorOutput: errorText)
    }
}
