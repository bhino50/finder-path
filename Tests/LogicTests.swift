import Darwin
import Foundation

private actor ControlledTailscaleFetcher {
    private var nextRequestID = 0
    private var continuations: [Int: CheckedContinuation<TailscaleStatus, Never>] = [:]

    var requestCount: Int { nextRequestID }

    func fetch() async -> TailscaleStatus {
        let requestID = nextRequestID
        nextRequestID += 1
        return await withCheckedContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func complete(requestID: Int, with status: TailscaleStatus) {
        continuations.removeValue(forKey: requestID)?.resume(returning: status)
    }
}

@main
struct FinderPathLogicTests {
    static func main() async {
        var failures: [String] = []
        var assertionCount = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertionCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        expect(UpdateChecker.compare("1.10", isNewerThan: "1.9"), "1.10 should be newer than 1.9")
        expect(!UpdateChecker.compare("1.6", isNewerThan: "1.6.0"), "equal padded versions should not update")
        expect(UpdateChecker.versionsAreEquivalent("v1.6", "1.6.0"), "v prefix and trailing zero should match")
        expect(!UpdateChecker.versionsAreEquivalent("", "0"), "empty versions must not match")
        expect(!UpdateChecker.versionsAreEquivalent("release", "0"), "nonnumeric versions must not match")

        // Update trust-gate regression cases, added by the updater audit.
        expect(!UpdateChecker.versionsAreEquivalent("18446744073709551616.9", "0.9"), "an overflowing version component cannot become zero during verification")
        expect(UpdateChecker.compare("18446744073709551616.9", isNewerThan: "9.9"), "large decimal version components retain their numeric order")
        expect(!UpdateChecker.versionsAreEquivalent("1..9", "1.9"), "empty numeric version components are rejected")
        expect(!UpdateChecker.versionsAreEquivalent("1.9.", "1.9"), "a trailing version separator cannot disappear during verification")
        expect(!UpdateChecker.versionsAreEquivalent("١.9", "0.9"), "non-ASCII digits cannot become zero during verification")
        expect(!UpdateChecker.compare("1.9-rc.99", isNewerThan: "1.9.1"), "prerelease suffix numbers do not become core version components")
        expect(UpdateChecker.versionsAreEquivalent("1.9-rc.2", "1.9.0-rc.2"), "core padding is independent of the full prerelease suffix")
        expect(!UpdateChecker.versionsAreEquivalent("1.9-rc.2", "1.9-rc.3"), "the complete prerelease suffix remains part of version verification")
        expect(UpdateChecker.parseManifest(Data(#"{"version":"1..9"}"#.utf8)) == nil, "a malformed manifest version is rejected")
        expect(UpdateChecker.parseManifest(Data(#"{"tag_name":"v1..9"}"#.utf8)) == nil, "a malformed GitHub release version is rejected")
        expect(!UpdateChecker.isHTTPSWebURL(URL(string: "https://user:password@example.com/update.zip")!), "update URLs cannot carry embedded credentials")
        expect(!UpdateChecker.isHTTPSWebURL(URL(string: "http://example.com/update.zip")!), "update redirects cannot downgrade to HTTP")

        // Exercise the production command helper with an inherited stderr
        // pipe. The old helper waited for the entire three-second child even
        // with a 0.1-second timeout; its replacement owns and stops that child.
        let updaterTimeoutStart = Date()
        let updaterTimeout = UpdateInstaller.run(
            "/bin/sh",
            ["-c", "/bin/sh -c 'trap \"\" TERM; exec /bin/sleep 3' & wait"],
            timeout: 0.1
        )
        expect(updaterTimeout.status != 0, "an updater timeout is always reported as failure")
        expect(Date().timeIntervalSince(updaterTimeoutStart) < 2.5, "an inherited pipe cannot extend an updater timeout beyond bounded cleanup")
        expect(updaterTimeout.errorOutput.contains("safety limit"), "an updater timeout retains its user-facing cause")
        let updaterVerbose = UpdateInstaller.run(
            "/bin/sh",
            ["-c", "/bin/dd if=/dev/zero bs=1024 count=128 1>&2"],
            timeout: 2
        )
        expect(updaterVerbose.status == 0, "a verbose update tool can complete while stderr drains")
        expect(updaterVerbose.errorOutput.utf8.count < 65_700, "updater diagnostics stay within their retained byte limit")
        expect(updaterVerbose.errorOutput.contains("Tool diagnostics were truncated."), "capped updater diagnostics report truncation")

        do {
            let updateFixtures = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinderPathUpdateTransactionTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: updateFixtures, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: updateFixtures) }

            func makeUpdateFixture(_ directory: URL, marker: String) throws {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(marker.utf8).write(to: directory.appendingPathComponent("marker"))
            }
            func updateMarker(_ directory: URL) -> String? {
                (try? Data(contentsOf: directory.appendingPathComponent("marker")))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            func makeUpdateCase(_ name: String) throws -> URL {
                let directory = updateFixtures.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            }
            let simulatedFailure = NSError(domain: "FinderPathUpdaterTests", code: 1)

            // A partial copy/verification failure must precede every rename
            // of the installed app and remove the temporary staging tree.
            let preparationCase = try makeUpdateCase("preparation-failure")
            let preparationTarget = preparationCase.appendingPathComponent("FinderPath.app")
            let preparationSource = preparationCase.appendingPathComponent("source.app")
            try makeUpdateFixture(preparationTarget, marker: "old")
            try makeUpdateFixture(preparationSource, marker: "new")
            var preparationScheduled = false
            do {
                try UpdateInstaller.stageAndReplaceApp(
                    at: preparationTarget,
                    with: preparationSource,
                    prepareStagedApp: { source, staged in
                        expect(updateMarker(preparationTarget) == "old", "the installed app remains complete while preparation runs")
                        expect(staged.deletingLastPathComponent().deletingLastPathComponent().path == preparationCase.path, "staging happens on the destination volume")
                        let attributes = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
                        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "update staging is private to the installing user")
                        try FileManager.default.copyItem(at: source, to: staged)
                        throw simulatedFailure
                    },
                    scheduleRelaunch: { _ in preparationScheduled = true }
                )
                expect(false, "a failed staging step must reject the transaction")
            } catch {
                expect(updateMarker(preparationTarget) == "old", "a preparation failure preserves the original installed app")
                expect(!preparationScheduled, "a preparation failure never schedules a relaunch")
                let preparationEntries = try FileManager.default.contentsOfDirectory(atPath: preparationCase.path)
                expect(preparationEntries.allSatisfy { !$0.hasPrefix(".FinderPathUpdate-") }, "a preparation failure removes its partial staging directory")
            }

            let successCase = try makeUpdateCase("success")
            let successTarget = successCase.appendingPathComponent("FinderPath.app")
            let successSource = successCase.appendingPathComponent("source.app")
            try makeUpdateFixture(successTarget, marker: "old")
            try makeUpdateFixture(successSource, marker: "new")
            var successScheduled = false
            let retired = try UpdateInstaller.stageAndReplaceApp(
                at: successTarget,
                with: successSource,
                prepareStagedApp: { source, staged in
                    expect(updateMarker(successTarget) == "old", "staging precedes replacement of the installed app")
                    try FileManager.default.copyItem(at: source, to: staged)
                },
                scheduleRelaunch: { target in
                    expect(target == successTarget && updateMarker(target) == "new", "relaunch scheduling sees the complete replacement at the intended path")
                    successScheduled = true
                }
            )
            expect(successScheduled && updateMarker(successTarget) == "new", "a successful transaction installs the staged app")
            expect(updateMarker(retired) == "old", "the previous app is retained until real launch success can be established")
            expect(updateMarker(successSource) == "new", "installing a staged copy preserves the verified source")

            let helperFailureCase = try makeUpdateCase("helper-failure")
            let helperFailureTarget = helperFailureCase.appendingPathComponent("FinderPath.app")
            let helperFailureStaged = helperFailureCase.appendingPathComponent("staged.app")
            try makeUpdateFixture(helperFailureTarget, marker: "old")
            try makeUpdateFixture(helperFailureStaged, marker: "new")
            do {
                try UpdateInstaller.replaceApp(at: helperFailureTarget, with: helperFailureStaged) { target in
                    expect(updateMarker(target) == "new", "the helper-failure fixture reaches the replacement phase")
                    throw simulatedFailure
                }
                expect(false, "a relaunch scheduling failure must reject the transaction")
            } catch {
                expect(updateMarker(helperFailureTarget) == "old", "a helper launch failure restores the previous app")
                let helperFailureEntries = try FileManager.default.contentsOfDirectory(atPath: helperFailureCase.path)
                expect(helperFailureEntries == ["FinderPath.app"], "successful rollback removes the displaced replacement")
            }

            let renameFailureCase = try makeUpdateCase("rename-failure")
            let renameFailureTarget = renameFailureCase.appendingPathComponent("FinderPath.app")
            try makeUpdateFixture(renameFailureTarget, marker: "old")
            var renameFailureScheduled = false
            do {
                try UpdateInstaller.replaceApp(at: renameFailureTarget, with: renameFailureCase.appendingPathComponent("missing.app")) { _ in
                    renameFailureScheduled = true
                }
                expect(false, "a failed staged-app rename must reject the transaction")
            } catch {
                expect(updateMarker(renameFailureTarget) == "old", "a failed staged-app rename restores the previous app")
                expect(!renameFailureScheduled, "a failed staged-app rename never schedules a relaunch")
            }

            let initialMoveFailureCase = try makeUpdateCase("initial-move-failure")
            let initialMoveStaged = initialMoveFailureCase.appendingPathComponent("staged.app")
            try makeUpdateFixture(initialMoveStaged, marker: "new")
            do {
                try UpdateInstaller.replaceApp(at: initialMoveFailureCase.appendingPathComponent("missing.app"), with: initialMoveStaged) { _ in
                    expect(false, "a missing original app must never schedule a relaunch")
                }
                expect(false, "a failed move of the original app must reject the transaction")
            } catch {
                expect(updateMarker(initialMoveStaged) == "new", "an initial rename failure preserves the complete staged replacement")
            }

            let unavailableBackupCase = try makeUpdateCase("unavailable-backup")
            let unavailableBackupTarget = unavailableBackupCase.appendingPathComponent("FinderPath.app")
            let unavailableBackupStaged = unavailableBackupCase.appendingPathComponent("staged.app")
            try makeUpdateFixture(unavailableBackupTarget, marker: "old")
            try makeUpdateFixture(unavailableBackupStaged, marker: "new")
            do {
                try UpdateInstaller.replaceApp(at: unavailableBackupTarget, with: unavailableBackupStaged) { _ in
                    for entry in try FileManager.default.contentsOfDirectory(at: unavailableBackupCase, includingPropertiesForKeys: nil)
                    where entry.lastPathComponent.hasPrefix(".FinderPath.app.old-") {
                        try FileManager.default.removeItem(at: entry)
                    }
                    throw simulatedFailure
                }
                expect(false, "an unavailable backup cannot be reported as a successful rollback")
            } catch {
                expect(updateMarker(unavailableBackupTarget) == "new", "failed rollback never deletes the only remaining complete app")
                expect(error.localizedDescription.contains("replacement was retained"), "an unavailable backup reports the retained replacement")
            }

            // The real monitor observes an archive violation while its child
            // is running. That child exits zero when terminated; policy still
            // must win over the otherwise successful process status.
            let policyRoot = try makeUpdateCase("policy-stop")
            let policyLink = policyRoot.appendingPathComponent("escape")
            let policyCommand = "trap 'exit 0' TERM; /bin/ln -s /etc "
                + ShellCommand.argument(policyLink.path, quoteStyle: "single")
                + "; while :; do /bin/sleep 1; done"
            let policyResult = UpdateInstaller.run("/bin/sh", ["-c", policyCommand], timeout: 2, expansionRoot: policyRoot)
            expect(policyResult.status != 0, "an archive policy failure cannot be converted into a successful exit")
            expect(policyResult.errorOutput.contains(UpdateInstaller.escapedContainmentMessage), "an archive policy failure preserves its rejection reason")

            let waiterStart = Date()
            let waiter = UpdateInstaller.run(
                "/bin/sh",
                ["-c", UpdateInstaller.relaunchScript(of: successTarget, processIdentifier: ProcessInfo.processInfo.processIdentifier, maximumWaitAttempts: 1)],
                timeout: 2
            )
            expect(waiter.status == 1, "the real relaunch waiter expires when the original process stays alive")
            expect(Date().timeIntervalSince(waiterStart) < 2, "a cancelled app termination cannot leave a permanent relaunch helper")

            // Retired bundles stay until a newer FinderPath launches from the
            // same folder. That launch trashes only exact updater leftovers
            // proven to be FinderPath copies no newer than itself.
            func makeBundle(_ url: URL, identifier: String = UpdateInstaller.expectedBundleID, version: String) throws {
                let contents = url.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version],
                    format: .xml,
                    options: 0
                ).write(to: contents.appendingPathComponent("Info.plist"))
            }
            func retiredName(_ uuid: String = UUID().uuidString) -> String { ".FinderPath.app.old-\(uuid)" }

            let cleanupCase = try makeUpdateCase("leftover-cleanup")
            let cleanupApp = cleanupCase.appendingPathComponent("FinderPath.app")
            try makeBundle(cleanupApp, version: "1.9.1")
            for version in ["1.9.2", "1.9.3"] {
                let source = updateFixtures.appendingPathComponent("source-\(version).app")
                try makeBundle(source, version: version)
                try UpdateInstaller.stageAndReplaceApp(
                    at: cleanupApp,
                    with: source,
                    prepareStagedApp: { try FileManager.default.copyItem(at: $0, to: $1) },
                    scheduleRelaunch: { _ in }
                )
            }
            let retiredByUpdates = try FileManager.default.contentsOfDirectory(atPath: cleanupCase.path)
                .filter { $0.hasPrefix(".FinderPath.app.old-") }
            expect(retiredByUpdates.count == 2, "each in-app update keeps the previous bundle beside the app")

            let lowercaseRetired = retiredName(UUID().uuidString.lowercased())
            try makeBundle(cleanupCase.appendingPathComponent(lowercaseRetired), version: "1.9.1")
            let keptNames = [
                "newer": retiredName(), "foreign": retiredName(), "running": retiredName(),
                "malformed": ".FinderPath.app.old-12345", "failed": ".FinderPath.app.failed-\(UUID().uuidString)",
                "staging": ".FinderPathUpdate-\(UUID().uuidString)", "untrashable": retiredName(),
                "linked": retiredName(), "linkedPlist": retiredName(),
            ]
            let keptURL = keptNames.mapValues { cleanupCase.appendingPathComponent($0) }
            try makeBundle(keptURL["newer"]!, version: "2.0")
            try makeBundle(keptURL["foreign"]!, identifier: "com.example.Other", version: "1.0")
            for key in ["running", "malformed", "failed", "untrashable"] {
                try makeBundle(keptURL[key]!, version: "1.0")
            }
            try FileManager.default.createDirectory(at: keptURL["staging"]!, withIntermediateDirectories: false)
            let externalBundle = updateFixtures.appendingPathComponent("external.app")
            try makeBundle(externalBundle, version: "1.0")
            try FileManager.default.createSymbolicLink(at: keptURL["linked"]!, withDestinationURL: externalBundle)
            try FileManager.default.createDirectory(at: keptURL["linkedPlist"]!.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: keptURL["linkedPlist"]!.appendingPathComponent("Contents/Info.plist"),
                withDestinationURL: externalBundle.appendingPathComponent("Contents/Info.plist")
            )

            let fixtureTrash = updateFixtures.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: fixtureTrash, withIntermediateDirectories: false)
            func moveToFixtureTrash(_ item: URL) throws {
                if item.lastPathComponent == keptNames["untrashable"] { throw simulatedFailure }
                try FileManager.default.moveItem(at: item, to: fixtureTrash.appendingPathComponent(item.lastPathComponent))
            }
            func runCleanup(identifier: String? = UpdateInstaller.expectedBundleID, app: URL = cleanupApp) -> [String] {
                UpdateLeftoverCleanup.run(
                    runningApp: app,
                    runningBundleIdentifier: identifier,
                    runningVersion: "1.9.3",
                    runningBundlePaths: [keptURL["running"]!.standardizedFileURL.path],
                    trash: moveToFixtureTrash
                )
            }

            expect(runCleanup(identifier: "io.github.bhino50.FinderPathDev").isEmpty, "a development build never cleans the folder it runs from")
            expect(runCleanup(app: cleanupCase.appendingPathComponent("Other.app")).isEmpty, "only a host named FinderPath.app cleans its folder")
            var trashedDuringInstall = ["not run"]
            let gateWasFree = UpdateInstaller.performExclusively { trashedDuringInstall = runCleanup() }
            expect(gateWasFree && trashedDuringInstall.isEmpty, "cleanup never races an update installation")

            let trashed = runCleanup()
            expect(Set(trashed) == Set(retiredByUpdates + [lowercaseRetired]), "retired FinderPath bundles no newer than the running app are trashed")
            let trashedEntries = try FileManager.default.contentsOfDirectory(atPath: fixtureTrash.path)
            expect(Set(trashedEntries) == Set(trashed), "cleanup trashes exactly the bundles it reports")
            for (reason, url) in keptURL {
                expect(
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
                        || FileManager.default.fileExists(atPath: url.path),
                    "cleanup keeps the \(reason) leftover"
                )
            }
            expect(FileManager.default.fileExists(atPath: externalBundle.path), "cleanup never follows a link out of the app folder")
            expect(FileManager.default.fileExists(atPath: cleanupApp.appendingPathComponent("Contents/Info.plist").path), "cleanup never touches the running app")

            let boundCase = try makeUpdateCase("leftover-cleanup-bound")
            let boundApp = boundCase.appendingPathComponent("FinderPath.app")
            try makeBundle(boundApp, version: "2.0")
            for _ in 0..<10 {
                try makeBundle(boundCase.appendingPathComponent(retiredName()), version: "1.0")
            }
            let boundedRun = UpdateLeftoverCleanup.run(
                runningApp: boundApp,
                runningBundleIdentifier: UpdateInstaller.expectedBundleID,
                runningVersion: "2.0",
                runningBundlePaths: [],
                trash: { try FileManager.default.removeItem(at: $0) }
            )
            expect(boundedRun.count == 8, "one launch trashes a bounded number of retired bundles")
        } catch {
            expect(false, "updater fixture setup or verification failed: \(error.localizedDescription)")
        }

        do {
            let archiveFixtures = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinderPathArchiveEntryTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: archiveFixtures, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: archiveFixtures) }
            let specialEntry = archiveFixtures.appendingPathComponent("fifo")
            let fifoCreated = mkfifo(specialEntry.path, 0o600) == 0
            expect(fifoCreated, "the archive special-file fixture creates its owned FIFO")
            if fifoCreated {
                expect(UpdateInstaller.expandedContentsViolation(at: archiveFixtures, maximumSize: 1_024, maximumEntries: 10, maximumDepth: 4) == UpdateInstaller.unsupportedEntryMessage, "an archive FIFO cannot enter bundle verification or copying")
                try FileManager.default.removeItem(at: specialEntry)
            }

            let realApp = archiveFixtures.appendingPathComponent("FinderPath.app")
            try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)
            let foundApp = try UpdateInstaller.findApp(in: archiveFixtures)
            expect(foundApp?.resolvingSymlinksInPath().path == realApp.resolvingSymlinksInPath().path, "archive selection accepts the real top-level app directory")
            try FileManager.default.removeItem(at: realApp)

            let nestedApp = archiveFixtures.appendingPathComponent("nested/FinderPath.app")
            try FileManager.default.createDirectory(at: nestedApp, withIntermediateDirectories: true)
            let nestedSelection = try UpdateInstaller.findApp(in: archiveFixtures)
            expect(nestedSelection == nil, "archive selection does not descend into unrelated directories")
            try FileManager.default.createSymbolicLink(atPath: realApp.path, withDestinationPath: "nested/FinderPath.app")
            do {
                _ = try UpdateInstaller.findApp(in: archiveFixtures)
                expect(false, "a symlink cannot substitute for the archive's top-level app")
            } catch {
                expect(FileManager.default.fileExists(atPath: nestedApp.path), "rejecting a symlink leaves its destination untouched")
            }
            try FileManager.default.removeItem(at: realApp)
            try Data("not an app".utf8).write(to: realApp)
            do {
                _ = try UpdateInstaller.findApp(in: archiveFixtures)
                expect(false, "a regular file cannot substitute for the archive's app bundle")
            } catch {
                expect(true, "an app-named regular file is rejected during archive selection")
            }
        } catch {
            expect(false, "archive fixture setup or verification failed: \(error.localizedDescription)")
        }

        // hdiutil attach exits while a helper it started keeps serving the
        // mounted volume. The installer copies the app out afterwards, so the
        // runner's post-exit cleanup must leave that helper alone.
        do {
            let imageFixtures = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinderPathDiskImageTests-\(UUID().uuidString)")
            let imageSource = imageFixtures.appendingPathComponent("source")
            let image = imageFixtures.appendingPathComponent("update.dmg")
            let work = imageFixtures.appendingPathComponent("work")
            let mountPoints = [imageFixtures.appendingPathComponent("mount"), work.appendingPathComponent("mount")]
            func runTool(_ arguments: [String]) -> Int32 {
                let tool = Process()
                tool.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                tool.arguments = arguments
                tool.standardOutput = FileHandle.nullDevice
                tool.standardError = FileHandle.nullDevice
                guard (try? tool.run()) != nil else { return -1 }
                tool.waitUntilExit()
                return tool.terminationStatus
            }
            defer {
                for mountPoint in mountPoints
                where FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("FinderPath.app").path) {
                    _ = runTool(["detach", mountPoint.path, "-force"])
                }
                try? FileManager.default.removeItem(at: imageFixtures)
            }
            let sourceContents = imageSource.appendingPathComponent("FinderPath.app/Contents")
            try FileManager.default.createDirectory(at: sourceContents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: sourceContents.appendingPathComponent("Info.plist"))

            if runTool(["create", "-quiet", "-fs", "HFS+", "-format", "UDZO", "-srcfolder", imageSource.path, image.path]) != 0 {
                print("Skipping disk-image update tests: hdiutil create is unavailable here.")
            } else {
                let attach = UpdateInstaller.run(
                    "/usr/bin/hdiutil",
                    ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoints[0].path],
                    timeout: 30,
                    postExitDescendants: .preserve
                )
                if attach.status == 0 {
                    expect(
                        FileManager.default.fileExists(atPath: mountPoints[0].appendingPathComponent("FinderPath.app/Contents/Info.plist").path),
                        "a preserved attach helper keeps the volume mounted after hdiutil exits"
                    )
                    let detach = UpdateInstaller.run("/usr/bin/hdiutil", ["detach", mountPoints[0].path, "-force"], timeout: 15)
                    expect(detach.status == 0, "the preserved attach helper is torn down by detach")
                } else {
                    print("Skipping disk-image attach check: \(attach.errorOutput)")
                }
                do {
                    let extracted = try UpdateInstaller.extractApp(from: image, into: work)
                    expect(
                        FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Contents/Info.plist").path),
                        "a disk-image update is copied out of its mounted volume"
                    )
                    expect(
                        !FileManager.default.fileExists(atPath: mountPoints[1].appendingPathComponent("FinderPath.app").path),
                        "disk-image extraction detaches its temporary volume"
                    )
                } catch {
                    // Only a host that also refuses a plain attach may skip.
                    if runTool(["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoints[0].path]) != 0 {
                        print("Skipping disk-image update tests: hdiutil attach is not permitted here.")
                    } else {
                        expect(false, "disk-image extraction failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            expect(false, "disk-image fixture setup failed: \(error.localizedDescription)")
        }

        // Browser recovery is a typed trust decision. Only an operational
        // download failure may expose the manifest's external URL; packages
        // that were rejected or never verified must remain fail-closed.
        expect(
            UpdateInstaller.InstallError.downloadFailed("network unavailable").browserRecoveryPolicy
                == .offerManifestDownload,
            "operational download failures may offer explicit browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.downloadRejected("unsafe redirect").browserRecoveryPolicy
                == .unavailable,
            "download safety rejections must not offer browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.extractionFailed("invalid archive").browserRecoveryPolicy
                == .unavailable,
            "unverified extraction failures must not offer browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.appNotFoundInArchive.browserRecoveryPolicy == .unavailable,
            "an archive without FinderPath.app must not offer browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.verificationFailed("team mismatch").browserRecoveryPolicy
                == .unavailable,
            "security-verification failures must not offer browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.installFailed("unknown state").browserRecoveryPolicy == .unavailable,
            "installation failures with unknown verification state must not offer browser recovery"
        )
        expect(
            UpdateInstaller.InstallError.noArchiveURL.browserRecoveryPolicy == .unavailable,
            "a missing archive must not gain browser recovery through the install-failure path"
        )
        expect(
            UpdateInstaller.InstallError.unsupportedHostBundle("io.github.bhino50.FinderPathDev")
                .browserRecoveryPolicy == .unavailable,
            "a development build cannot escape isolation through browser recovery"
        )
        expect(
            UpdateInstaller.installerHostIsEligible(bundleIdentifier: "io.github.bhino50.FinderPath"),
            "the official bundle may install a verified update"
        )
        expect(
            !UpdateInstaller.installerHostIsEligible(bundleIdentifier: "io.github.bhino50.FinderPathDev"),
            "a development build cannot replace itself with the production bundle"
        )
        expect(
            !UpdateInstaller.installerHostIsEligible(bundleIdentifier: nil),
            "an unidentified host bundle fails closed before update download"
        )
        expect(
            UpdateInstaller.classifyDownloadError(URLError(.notConnectedToInternet)).browserRecoveryPolicy
                == .offerManifestDownload,
            "an explicit offline error remains an operational recovery case"
        )
        expect(
            UpdateInstaller.classifyDownloadError(URLError(.secureConnectionFailed)).browserRecoveryPolicy
                == .unavailable,
            "TLS failures must not be reclassified as browser-recoverable"
        )
        expect(
            UpdateInstaller.classifyDownloadError(NSError(domain: "FinderPathTests", code: 1))
                .browserRecoveryPolicy == .unavailable,
            "unknown download errors must fail closed"
        )

        expect(
            UpdateInstaller.operationTimeoutMessage(seconds: 120)
                == "The update operation exceeded its 120-second safety limit.",
            "the operation timeout message must interpolate its exact limit"
        )
        expect(
            UpdateInstaller.expandedEntryCountMessage(maximumEntries: 50_000)
                == "The expanded update contained more than 50000 entries.",
            "the expanded-entry message must interpolate its exact limit"
        )
        expect(
            UpdateInstaller.expandedPathDepthMessage(maximumDepth: 64)
                == "The expanded update exceeded the maximum path depth of 64.",
            "the expanded-depth message must interpolate its exact limit"
        )
        expect(
            UpdateInstaller.expandedSizeLimitMessage(maximumSize: 1_024 * 1_024 * 1_024)
                == "The expanded update exceeded the 1024 MB safety limit.",
            "the expanded-size message must interpolate its exact limit"
        )

        // Extraction is monitored before an update bundle is trusted. Exercise
        // each quota against a tiny temporary tree rather than installing.
        let quotaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathQuotaTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: quotaRoot) }
        try? FileManager.default.createDirectory(at: quotaRoot, withIntermediateDirectories: true)
        let quotaFile = quotaRoot.appendingPathComponent("payload")
        try? Data(repeating: 0x41, count: 32).write(to: quotaFile)
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot,
                maximumSize: 64,
                maximumEntries: 10,
                maximumDepth: 4
            ) == nil,
            "a small extracted update stays within its quotas"
        )
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot,
                maximumSize: 16,
                maximumEntries: 10,
                maximumDepth: 4
            ) != nil,
            "expanded update bytes are capped"
        )
        let secondQuotaFile = quotaRoot.appendingPathComponent("second")
        try? Data([0x42]).write(to: secondQuotaFile)
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot,
                maximumSize: 64,
                maximumEntries: 1,
                maximumDepth: 4
            ) != nil,
            "expanded update entry count is capped"
        )
        // Zip-slip defense in depth: a link that resolves outside the
        // extraction root fails inspection before any signature check runs.
        let escapingLink = quotaRoot.appendingPathComponent("escape")
        try? FileManager.default.createSymbolicLink(atPath: escapingLink.path, withDestinationPath: "/etc")
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot, maximumSize: 1_024, maximumEntries: 10, maximumDepth: 4
            ) == UpdateInstaller.escapedContainmentMessage,
            "an absolute symlink out of the package is rejected"
        )
        try? FileManager.default.removeItem(at: escapingLink)
        let climbingLink = quotaRoot.appendingPathComponent("climb")
        try? FileManager.default.createSymbolicLink(atPath: climbingLink.path, withDestinationPath: "../../outside")
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot, maximumSize: 1_024, maximumEntries: 10, maximumDepth: 4
            ) == UpdateInstaller.escapedContainmentMessage,
            "a relative symlink that climbs out of the package is rejected"
        )
        try? FileManager.default.removeItem(at: climbingLink)
        let internalLink = quotaRoot.appendingPathComponent("alias")
        try? FileManager.default.createSymbolicLink(atPath: internalLink.path, withDestinationPath: "payload")
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot, maximumSize: 1_024, maximumEntries: 10, maximumDepth: 4
            ) == nil,
            "a symlink that stays inside the package is allowed"
        )
        try? FileManager.default.removeItem(at: internalLink)
        let deepQuotaDirectory = quotaRoot.appendingPathComponent("one/two")
        try? FileManager.default.createDirectory(at: deepQuotaDirectory, withIntermediateDirectories: true)
        expect(
            UpdateInstaller.expandedContentsViolation(
                at: quotaRoot,
                maximumSize: 64,
                maximumEntries: 10,
                maximumDepth: 1
            ) != nil,
            "expanded update path depth is capped"
        )

        expect(RemoteServers.normalizedTarget("ssh user@example.com") == "user@example.com", "ssh prefix should normalize")
        expect(RemoteServers.normalizedTarget("ssh -- example.com") == "example.com", "ssh -- prefix should normalize")
        expect(RemoteServers.normalizedTarget("'example.com'") == "example.com", "matching quotes should normalize")
        expect(RemoteServers.isValidTarget("admin@dev.example.com"), "normal user@host should be valid")
        expect(RemoteServers.isValidTarget("::1"), "IPv6 loopback should be valid")
        expect(!RemoteServers.isValidTarget("-oProxyCommand=bad"), "leading option should be rejected")
        expect(!RemoteServers.isValidTarget("user@@host"), "multiple at signs should be rejected")
        expect(!RemoteServers.isValidTarget("@"), "empty user and host should be rejected")
        expect(!RemoteServers.isValidTarget("ssh host"), "whitespace should be rejected")

        let servers = [
            RemoteServer(name: "Dev", target: "admin@dev.example.com"),
            RemoteServer(name: "Local", target: "localhost")
        ]
        expect(RemoteServers.parse(RemoteServers.serialize(servers)) == servers, "server persistence should round-trip")

        // The visible row, including a refreshed hostname, owns the SSH target.
        // Hiding or removing a row must make Connect unavailable.
        let selectedDevice = TailscaleDevice(
            name: "old-host", address: "100.64.0.9", os: "macOS", online: true
        )
        let renamedDevice = TailscaleDevice(
            name: "new-host", address: selectedDevice.address, os: "macOS", online: true
        )
        let deviceSelection = "ts:\(selectedDevice.id)"
        expect(
            RemoteConnectionSelection.target(for: deviceSelection, servers: [], visibleDevices: [selectedDevice]) == "old-host",
            "selecting a visible device resolves its current hostname"
        )
        expect(
            RemoteConnectionSelection.target(for: deviceSelection, servers: [], visibleDevices: [renamedDevice]) == "new-host",
            "a refresh that renames the selected device updates the connection target"
        )
        expect(
            RemoteConnectionSelection.target(for: deviceSelection, servers: [], visibleDevices: [selectedDevice].filter(\.isLinux)) == nil,
            "filtering out the selected device disables its connection"
        )
        expect(
            RemoteConnectionSelection.target(for: deviceSelection, servers: [], visibleDevices: []) == nil,
            "removing the selected device disables its connection"
        )
        let unnamedDevice = TailscaleDevice(name: "", address: selectedDevice.address, os: "linux", online: false)
        expect(
            RemoteConnectionSelection.target(for: deviceSelection, servers: [], visibleDevices: [unnamedDevice]) == selectedDevice.address,
            "a device without a name uses the displayed address"
        )
        expect(
            RemoteConnectionSelection.target(for: "srv:0", servers: servers, visibleDevices: []) == servers[0].target,
            "a saved server resolves to the current row target"
        )
        for invalidSelection in [nil, "srv:-1", "srv:\(servers.count)", "srv:invalid", "ts:missing", "unknown:0"] as [String?] {
            expect(
                RemoteConnectionSelection.target(for: invalidSelection, servers: servers, visibleDevices: [selectedDevice]) == nil,
                "missing or invalid selections do not connect"
            )
        }

        // The Tailscale device list must show every device by default. Filtering
        // it to Linux hosts hid every online Windows and macOS server on a real
        // tailnet, and the toggle was view state that reset on every launch —
        // so the machines came back hidden after each login.
        let showAllKey = FinderPathPreferences.showAllTailscaleDevicesKey
        UserDefaults.standard.removeObject(forKey: showAllKey)
        FinderPathPreferences.registerDefaults()
        expect(FinderPathPreferences.showAllTailscaleDevices, "Tailscale devices should default to showing all")
        UserDefaults.standard.set(false, forKey: showAllKey)
        expect(!FinderPathPreferences.showAllTailscaleDevices, "an explicit Linux-only choice must persist")
        UserDefaults.standard.set(true, forKey: showAllKey)
        expect(FinderPathPreferences.showAllTailscaleDevices, "re-enabling show all must persist")
        UserDefaults.standard.removeObject(forKey: showAllKey)

        // MARK: - Tailscale process decoding and refresh ordering

        func capturedOutput(
            stdout: String = "",
            stderr: String = "",
            stdoutWasTruncated: Bool = false,
            stderrWasTruncated: Bool = false
        ) -> BoundedProcessRunner.CapturedOutput {
            BoundedProcessRunner.CapturedOutput(
                standardOutput: Data(stdout.utf8),
                standardError: Data(stderr.utf8),
                standardOutputWasTruncated: stdoutWasTruncated,
                standardErrorWasTruncated: stderrWasTruncated
            )
        }

        let tailscaleJSON = """
        {
          "BackendState": "Running",
          "Self": { "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"] },
          "Peer": {
            "peer-z": {
              "DNSName": "zeta.example.ts.net.",
              "HostName": "IGNORED-HOSTNAME",
              "TailscaleIPs": ["100.64.0.3"],
              "OS": "windows",
              "Online": false
            },
            "peer-a": {
              "HostName": "Alpha",
              "TailscaleIPs": ["100.64.0.2"],
              "OS": "linux",
              "Online": true
            },
            "peer-b": {
              "DNSName": "beta.example.ts.net.",
              "OS": "macOS",
              "Online": true
            }
          }
        }
        """
        let decodedStatus = TailscaleBridge.status(from: .exited(
            status: 0,
            output: capturedOutput(stdout: tailscaleJSON)
        ))
        expect(decodedStatus.backend == .running, "Tailscale Running JSON maps to a running backend")
        expect(decodedStatus.selfAddress == "100.64.0.1", "the first self Tailscale address is retained")
        expect(
            decodedStatus.devices.map(\.name) == ["Alpha", "beta", "zeta"],
            "online peers sort first and MagicDNS short names take precedence"
        )
        expect(
            decodedStatus.devices.map(\.online) == [true, true, false],
            "peer online state survives JSON decoding"
        )
        expect(
            decodedStatus.devices[1].address.isEmpty && decodedStatus.devices[1].os == "macOS",
            "optional peer fields receive stable defaults without dropping the peer"
        )
        expect(decodedStatus.failure == nil, "valid Tailscale status has no typed failure")

        let noState = TailscaleBridge.decodeStatus(Data(#"{"BackendState":"NoState"}"#.utf8))
        expect(noState.backend == .needsLogin, "NoState maps to the sign-in-required state")
        let stopped = TailscaleBridge.decodeStatus(Data(#"{"BackendState":"Starting"}"#.utf8))
        expect(stopped.backend == .stopped, "non-running daemon states map to stopped")
        expect(
            TailscaleBridge.decodeStatus(Data(#"{"Peer":{}}"#.utf8)).failure == .malformedStatus,
            "a status payload without BackendState fails as malformed"
        )
        expect(
            TailscaleBridge.decodeStatus(Data("not json".utf8)).failure == .malformedStatus,
            "invalid status JSON fails as malformed"
        )

        expect(
            TailscaleBridge.status(from: .executableNotFound(path: "/missing")).failure
                == .executableNotFound,
            "a missing Tailscale executable remains a typed failure"
        )
        expect(
            TailscaleBridge.status(from: .timedOut(output: capturedOutput())).failure
                == .timedOut(command: TailscaleBridge.statusCommand),
            "a Tailscale status timeout remains a typed failure"
        )
        expect(
            TailscaleBridge.status(from: .launchFailed(message: "spawn denied")).failure
                == .launchFailed(command: TailscaleBridge.statusCommand, detail: "spawn denied"),
            "a Tailscale launch failure retains its detail"
        )
        expect(
            TailscaleBridge.status(from: .exited(
                status: 7,
                output: capturedOutput(stderr: "permission denied\n")
            )).failure == .commandFailed(
                command: TailscaleBridge.statusCommand,
                exitStatus: 7,
                detail: "permission denied"
            ),
            "a nonzero Tailscale status retains exit status and trimmed stderr"
        )
        expect(
            TailscaleBridge.status(from: .exited(
                status: 0,
                output: capturedOutput(stdout: tailscaleJSON, stdoutWasTruncated: true)
            )).failure == .outputLimitExceeded(command: TailscaleBridge.statusCommand),
            "truncated successful status output fails closed before JSON decoding"
        )

        let longDiagnostic = String(repeating: "x", count: 700)
        let failedCommand = TailscaleBridge.commandOutcome(
            from: .exited(
                status: 9,
                output: capturedOutput(
                    stderr: longDiagnostic,
                    stderrWasTruncated: true
                )
            ),
            command: "tailscale up"
        )
        if case .failure(.commandFailed(let command, let exitStatus, let detail)) = failedCommand {
            expect(command == "tailscale up", "command failure identifies the exact subcommand")
            expect(exitStatus == 9, "command failure retains its exit status")
            expect(detail?.count == 501, "a truncated diagnostic is capped and marked with an ellipsis")
            expect(detail?.hasSuffix("…") == true, "a truncated diagnostic visibly reports shortening")
        } else {
            expect(false, "a failed side-effect command remains a typed command failure")
        }
        expect(
            TailscaleBridge.commandOutcome(
                from: .exited(status: 0, output: capturedOutput(stdoutWasTruncated: true)),
                command: "tailscale down"
            ) == .success,
            "unused side-effect command output may be discarded even when capped"
        )

        let controlledFetcher = ControlledTailscaleFetcher()
        let refreshCache = TailscaleStatusCache {
            await controlledFetcher.fetch()
        }
        let staleStatus = TailscaleStatus(
            backend: .stopped,
            selfAddress: nil,
            devices: [],
            failure: nil
        )
        let freshStatus = TailscaleStatus(
            backend: .running,
            selfAddress: "100.64.0.99",
            devices: [],
            failure: nil
        )

        let originalRefresh = Task {
            await refreshCache.status(forceRefresh: false, maxAge: 60)
        }
        for _ in 0..<1_000 {
            if await controlledFetcher.requestCount >= 1 { break }
            await Task.yield()
        }
        let initialRequestCount = await controlledFetcher.requestCount
        expect(initialRequestCount == 1, "the initial status lookup starts one fetch")

        let forcedRefresh = Task {
            await refreshCache.status(forceRefresh: true, maxAge: 60)
        }
        for _ in 0..<1_000 {
            if await controlledFetcher.requestCount >= 2 { break }
            await Task.yield()
        }
        let joinedRefresh = Task {
            await refreshCache.status(forceRefresh: false, maxAge: 60)
        }
        for _ in 0..<100 { await Task.yield() }
        let overlappingRequestCount = await controlledFetcher.requestCount
        expect(
            overlappingRequestCount == 2,
            "a non-forced lookup joins the newest forced refresh instead of spawning a third fetch"
        )

        // Resolve the obsolete request first. It must wait for and return the
        // forced result instead of exposing stale state to its original caller.
        await controlledFetcher.complete(requestID: 0, with: staleStatus)
        for _ in 0..<100 { await Task.yield() }
        await controlledFetcher.complete(requestID: 1, with: freshStatus)

        let originalResult = await originalRefresh.value
        let forcedResult = await forcedRefresh.value
        let joinedResult = await joinedRefresh.value
        expect(originalResult == freshStatus, "an older overlapping caller is redirected to the forced result")
        expect(forcedResult == freshStatus, "the forced caller receives its fresh result")
        expect(joinedResult == freshStatus, "a non-forced overlapping caller receives the fresh result")

        let cachedResult = await refreshCache.status(forceRefresh: false, maxAge: 60)
        let finalRequestCount = await controlledFetcher.requestCount
        expect(cachedResult == freshStatus, "the newest forced result is the value committed to cache")
        expect(finalRequestCount == 2, "a fresh cache hit does not invoke the fetcher again")

        // Prerelease builds of the same version must not be treated as equal:
        // UpdateInstaller.verify uses this to gate replacing the running app.
        expect(!UpdateChecker.versionsAreEquivalent("1.7-beta", "1.7-rc"), "different prereleases must not match")
        expect(UpdateChecker.versionsAreEquivalent("1.7-beta", "v1.7-BETA"), "the same prerelease still matches")
        expect(!UpdateChecker.versionsAreEquivalent("1.7", "1.7-beta"), "a prerelease must not match the release")
        expect(UpdateChecker.versionsAreEquivalent("v1.7", "1.7.0"), "plain releases still match across padding")
        expect(
            !UpdateChecker.versionsAreEquivalent("1.7-dev", "1.7-de"),
            "a v inside a prerelease suffix must not be stripped during verification"
        )
        // Ordering follows SemVer precedence: the numeric core decides first,
        // prerelease identifiers only break a tie, build metadata never counts.
        expect(UpdateChecker.compare("1.8-beta", isNewerThan: "1.7"), "a higher-core prerelease is still offered")
        expect(UpdateChecker.compare("1.9.3", isNewerThan: "1.9.3-rc.1"), "a prerelease user is offered the matching final release")
        expect(UpdateChecker.compare("v1.9.3.0", isNewerThan: "1.9.3-RC.1"), "a padded final release outranks its prerelease")
        expect(UpdateChecker.compare("1.9.3+build.7", isNewerThan: "1.9.3-rc.1"), "build metadata does not make a release a prerelease")
        expect(UpdateChecker.compare("1.9.3-rc.2", isNewerThan: "1.9.3-rc.1"), "later prereleases of one core are ordered")
        expect(UpdateChecker.compare("1.9.3-rc.10", isNewerThan: "1.9.3-rc.2"), "numeric prerelease identifiers compare numerically")
        expect(UpdateChecker.compare("1.9.3-rc", isNewerThan: "1.9.3-beta.5"), "alphanumeric prerelease identifiers compare in ASCII order")
        expect(UpdateChecker.compare("1.9.3-rc.1", isNewerThan: "1.9.3-rc"), "a longer prerelease with an equal prefix is newer")
        expect(UpdateChecker.compare("1.9.3-alpha", isNewerThan: "1.9.3-1"), "numeric prerelease identifiers rank below alphanumeric ones")
        expect(UpdateChecker.compare("1.9.3-rc.2+b1", isNewerThan: "1.9.3-rc.1+b9"), "build metadata is ignored when ordering prereleases")
        expect(!UpdateChecker.compare("1.9.3-rc.1", isNewerThan: "1.9.3"), "a final-release user is never offered a prerelease of the same core")
        expect(!UpdateChecker.compare("1.9.3-rc.9", isNewerThan: "1.9.3.0"), "a prerelease never outranks its padded final release")
        expect(!UpdateChecker.compare("1.9.3-rc.2", isNewerThan: "1.9.3-rc.10"), "prerelease numbers are not compared as text")
        expect(!UpdateChecker.compare("1.9.3-rc.1", isNewerThan: "1.9.3-rc.1"), "an identical prerelease is not an update")
        expect(!UpdateChecker.compare("1.9.3-rc.01", isNewerThan: "1.9.3-rc.1"), "leading zeros do not change a numeric prerelease identifier")
        expect(!UpdateChecker.compare("1.9.3+build.7", isNewerThan: "1.9.3"), "build metadata alone is not an update")
        expect(!UpdateChecker.compare("1.9.3", isNewerThan: "1.9.3+build.7"), "a release without build metadata is not an update")
        expect(!UpdateChecker.compare("1.9.2", isNewerThan: "1.9.3-rc.1"), "the numeric core still decides before prerelease identifiers")
        expect(UpdateChecker.compare("1.9.3-rc.1", isNewerThan: "1.9.2"), "a prerelease of a higher core is newer than an older release")
        expect(!UpdateChecker.compare("1.9.3", isNewerThan: "1.9.3"), "an identical release is not an update")

        // A display name is stored in line-oriented `Name = target` text, so it
        // must survive the round trip rather than deleting or duplicating rows.
        let awkwardName = [RemoteServer(name: "Dev = Prod", target: "dev.example.com")]
        let awkwardRoundTrip = RemoteServers.parse(RemoteServers.serialize(awkwardName))
        expect(awkwardRoundTrip.count == 1, "a name containing '=' must not delete the server")
        expect(awkwardRoundTrip.first?.target == "dev.example.com", "the target survives an awkward name")
        expect(awkwardRoundTrip.first?.name == "Dev - Prod", "the '=' is replaced rather than splitting the line")

        let multilineName = [RemoteServer(name: "Dev\nEvil = evil.example.com", target: "dev.example.com")]
        let multilineRoundTrip = RemoteServers.parse(RemoteServers.serialize(multilineName))
        expect(multilineRoundTrip.count == 1, "a newline in a name must not inject a second server")
        expect(multilineRoundTrip.first?.target == "dev.example.com", "the injected host is not created")

        let commentName = [RemoteServer(name: "#Dev", target: "dev.example.com")]
        let commentRoundTrip = RemoteServers.parse(RemoteServers.serialize(commentName))
        expect(commentRoundTrip.count == 1, "a leading '#' must not comment the line out")
        expect(commentRoundTrip.first?.name == "Dev", "the comment marker is stripped from the name")

        expect(RemoteServers.sanitizedName("  spaced  ") == "spaced", "names are trimmed")
        expect(RemoteServers.sanitizedName("###") == "", "an all-marker name collapses to empty")

        expect(ShellCommand.argument("it's here") == "'it'\\''s here'", "single-quote escaping should be shell-safe")
        expect(
            ShellCommand.argument("/tmp/folder!history", quoteStyle: "double") == "'/tmp/folder!history'",
            "double-quote preference must not expose interactive shell history expansion"
        )
        expect(
            ShellCommand.argument("/tmp/it's!here", quoteStyle: "double") == "'/tmp/it'\\''s!here'",
            "history-safe fallback must also preserve apostrophes"
        )
        expect(
            ShellCommand.argument("$HOME/`pwd`/\"folder\"", quoteStyle: "double")
                == "\"\\$HOME/\\`pwd\\`/\\\"folder\\\"\"",
            "double-quote escaping should protect substitutions"
        )
        expect(
            TerminalBridge.escapedAppleScriptString("one\rtwo\n\"three\"\\four")
                == "one\\rtwo\\n\\\"three\\\"\\\\four",
            "Terminal AppleScript strings should escape CR, LF, quotes, and backslashes"
        )
        // Folder names may legally contain a newline. Collapsing it to a space
        // rewrote the cd target, so the escape has to preserve the byte.
        expect(
            TerminalBridge.escapedAppleScriptString("/tmp/a\nb") == "/tmp/a\\nb",
            "a newline in a folder path should escape rather than collapse to a space"
        )

        // Agent launches are typed into the user's login shell, which may be
        // fish or tcsh. Every one of them reads `\x` outside quotes as x.
        expect(ShellCommand.portableArgument("") == "''", "an empty portable argument stays one word")
        expect(
            ShellCommand.portableArgument("/tmp/plain dir") == "'/tmp/plain dir'",
            "ordinary characters stay inside single quotes"
        )
        expect(
            ShellCommand.portableArgument("it's a\\b!") == "'it'\\''s a'\\\\'b'\\!",
            "quote, backslash, and bang are escaped outside the quotes"
        )
        expect(
            ShellCommand.portableArgument("'\u{301}") == "\\''\u{301}'",
            "a combining mark cannot hide a quote inside a quoted run"
        )
        expect(
            ShellCommand.portableArgument(TerminalBridge.agentLaunchScript) == "'\(TerminalBridge.agentLaunchScript)'",
            "the fixed launch program stays a single quoted word"
        )
        // Outside the quoted arguments only plain words may remain: `if`/`fi`,
        // `&&`, and `${...}` are what fish and tcsh reject.
        let agentCommand = TerminalBridge.agentLaunchCommand(
            displayName: "Claude", executable: "/Users/u/.local/bin/claude", directoryPath: "/Users/u/it's a\\dir!"
        )
        var unquotedAgentText = ""
        var insideQuotes = false
        var afterBackslash = false
        for scalar in agentCommand.unicodeScalars {
            if afterBackslash {
                afterBackslash = false
            } else if insideQuotes {
                insideQuotes = scalar != "'"
            } else if scalar == "\\" {
                afterBackslash = true
            } else if scalar == "'" {
                insideQuotes = true
            } else {
                unquotedAgentText.unicodeScalars.append(scalar)
            }
        }
        expect(
            unquotedAgentText == "exec /bin/sh -c     " && !insideQuotes && !afterBackslash,
            "the agent launch line is plain words around balanced quoted arguments"
        )
        let missingAgentMessage = TerminalBridge.agentMissingMessage(
            displayName: "Claude", executable: "/opt/homebrew/bin/claude"
        )
        expect(
            missingAgentMessage.contains("/opt/homebrew/bin/claude") && missingAgentMessage.contains("Settings"),
            "the missing-agent message names the checked path and where to change it"
        )
        expect(
            !missingAgentMessage.contains("PATH"),
            "the missing-agent message never asks for a file path to be added to PATH"
        )
        expect(
            AgentLauncher.commonSearchDirectories.allSatisfy(AgentLauncher.searchLocationsSummary.contains),
            "the Settings footnote lists every folder a bare command name is looked up in"
        )

        // The Ghostty SSH path opens a throwaway script as a document so the
        // running instance is reused; the host must stay shell-quoted in it.
        expect(
            TerminalBridge.sshLaunchScriptSource(host: "user@host")
                == "#!/bin/sh\nexec ssh -- 'user@host'",
            "the Ghostty SSH launch script should exec ssh against the quoted host"
        )
        expect(
            TerminalBridge.sshLaunchScriptSource(host: "a'b").contains("'a'\\''b'"),
            "a host containing a quote should stay inside single quotes"
        )

        // Hovering the status item quick-picks an open terminal session. The
        // picker must never appear when disabled, when there is nothing to
        // pick, or when the menu or terminal panel already owns the screen.
        let hoverKey = FinderPathPreferences.hoverShowsTerminalsKey
        UserDefaults.standard.removeObject(forKey: hoverKey)
        FinderPathPreferences.registerDefaults()
        expect(FinderPathPreferences.hoverShowsTerminals, "hover quick-pick should be enabled by default")
        UserDefaults.standard.set(false, forKey: hoverKey)
        expect(!FinderPathPreferences.hoverShowsTerminals, "disabling hover quick-pick must persist")
        UserDefaults.standard.removeObject(forKey: hoverKey)

        // Process-launching custom URLs are callable by any local process, so
        // they remain off until the user explicitly trusts a shortcut tool.
        let externalLaunchURLsKey = FinderPathPreferences.allowExternalLaunchURLsKey
        UserDefaults.standard.removeObject(forKey: externalLaunchURLsKey)
        FinderPathPreferences.registerDefaults()
        expect(!FinderPathPreferences.allowExternalLaunchURLs, "external launch URLs default to disabled")
        UserDefaults.standard.set(true, forKey: externalLaunchURLsKey)
        expect(FinderPathPreferences.allowExternalLaunchURLs, "external launch URL opt-in persists")
        UserDefaults.standard.removeObject(forKey: externalLaunchURLsKey)

        // Every menu row has a visibility toggle; Recent Paths follows suit and
        // ships on, with an explicit off choice surviving relaunch.
        let recentPathsKey = FinderPathPreferences.showRecentPathsItemKey
        UserDefaults.standard.removeObject(forKey: recentPathsKey)
        FinderPathPreferences.registerDefaults()
        expect(FinderPathPreferences.showRecentPathsItem, "Recent Paths should be shown by default")
        UserDefaults.standard.set(false, forKey: recentPathsKey)
        expect(!FinderPathPreferences.showRecentPathsItem, "hiding Recent Paths must persist")
        UserDefaults.standard.removeObject(forKey: recentPathsKey)

        expect(
            HoverPickerLogic.shouldPresent(enabled: true, sessionCount: 2, isMenuTracking: false, isPanelVisible: false),
            "hover with open sessions should present the picker"
        )
        expect(
            !HoverPickerLogic.shouldPresent(enabled: false, sessionCount: 2, isMenuTracking: false, isPanelVisible: false),
            "a disabled picker must never present"
        )
        expect(
            !HoverPickerLogic.shouldPresent(enabled: true, sessionCount: 0, isMenuTracking: false, isPanelVisible: false),
            "no sessions means nothing to pick"
        )
        expect(
            !HoverPickerLogic.shouldPresent(enabled: true, sessionCount: 1, isMenuTracking: true, isPanelVisible: false),
            "the status menu owns the screen while tracking"
        )
        expect(
            !HoverPickerLogic.shouldPresent(enabled: true, sessionCount: 1, isMenuTracking: false, isPanelVisible: true),
            "an open terminal panel already shows the sessions"
        )

        // Terminal launched cold by an Apple event still opens its startup
        // window before servicing `do script`, so an unconditional `do script`
        // produced two windows per launch. The script must capture the running
        // state before any event, reuse the startup window on a cold launch,
        // and fall back to a new window when no startup window exists.
        let launchScript = TerminalBridge.terminalLaunchScriptSource(command: "echo \"hi\"")
        expect(
            launchScript.contains("set launchCommand to \"echo \\\"hi\\\"\""),
            "the launch command should be AppleScript-escaped into a single variable"
        )
        expect(
            launchScript.components(separatedBy: "echo").count == 2,
            "the command text should be embedded exactly once"
        )
        expect(
            launchScript.contains("do script launchCommand in window 1"),
            "a cold launch must reuse Terminal's startup window instead of opening a second one"
        )
        expect(
            launchScript.contains("on error"),
            "a cold launch without a startup window must fall back to a new window"
        )
        if let runningCheck = launchScript.range(of: "is running"),
           let tellBlock = launchScript.range(of: "tell application") {
            expect(
                runningCheck.lowerBound < tellBlock.lowerBound,
                "the running state must be read before the tell block sends any launching event"
            )
        } else {
            expect(false, "the launch script must check Terminal's running state outside the tell block")
        }

        expect(AgentLauncher.availability(for: "/bin/sh").resolvedPath == "/bin/sh", "absolute executables should resolve")
        expect(AgentLauncher.availability(for: "sh").isInstalled, "PATH executables should resolve")
        expect(!AgentLauncher.availability(for: "finderpath-command-that-does-not-exist").isInstalled, "missing executables should not resolve")
        let directoryNamedLikeAgent = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathAgentDir-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directoryNamedLikeAgent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryNamedLikeAgent) }
        expect(
            !AgentLauncher.availability(for: directoryNamedLikeAgent.path).isInstalled,
            "a directory is never an installed agent, even with the search bit set"
        )
        expect(
            AgentLauncher.menuPresentation(name: "Codex", optionHeld: false)
                == .init(title: "Open with Codex", usesBuiltInTerminal: false),
            "normal harness menu row should use the external launcher"
        )
        expect(
            AgentLauncher.menuPresentation(name: "Codex", optionHeld: true)
                == .init(title: "Open with Codex in FinderPath Terminal", usesBuiltInTerminal: true),
            "Option-held harness menu row should use FinderPath Terminal"
        )

        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "/Users/demo/Documents\n",
                stderr: ""
            ).path == "/Users/demo/Documents",
            "successful query should remove the osascript record terminator"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: true,
                stdout: "/tmp\n",
                stderr: ""
            ).path == "/tmp",
            "a completed query should win over a racing timeout"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)"
            ).path == FinderBridge.permissionDeniedMessage,
            "automation denial should map to the permission message"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            ).path == FinderBridge.finderStalledMessage,
            "a watchdog kill should report Finder as not responding"
        )
        let deniedFinderResult = FinderBridge.interpretScriptResult(
            terminationStatus: 1,
            timedOut: false,
            stdout: "",
            stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)"
        )
        expect(
            deniedFinderResult.path == FinderBridge.permissionDeniedMessage,
            "Finder permission denial should keep its actionable message"
        )
        expect(
            deniedFinderResult.failure == .permissionDenied,
            "Finder permission denial must be typed separately from operational failures"
        )

        let failedFinderResult = FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Finder got an error: AppleEvent timed out. (-1712)"
            )
        expect(
            failedFinderResult.path.hasPrefix("Finder AppleScript error:"),
            "other script failures should surface as error strings"
        )
        expect(
            failedFinderResult.failure == .queryFailed,
            "non-permission Finder failures must not route users to Automation settings"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "",
                stderr: ""
            ).path.hasPrefix("/"),
            "empty output should fall back to a local folder"
        )

        // The query script tags its answer so the recent-paths history can tell
        // a folder the user actually had open from the desktop substitution.
        let windowResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "window\n/Users/demo/Documents\n",
            stderr: ""
        )
        expect(windowResult.path == "/Users/demo/Documents", "a window-tagged result returns the path")
        expect(!windowResult.isFallback, "a real Finder window is not a fallback")

        let fallbackResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "fallback\n/Users/demo/Desktop\n",
            stderr: ""
        )
        expect(fallbackResult.path == "/Users/demo/Desktop", "a fallback-tagged result still returns the path")
        expect(fallbackResult.isFallback, "a desktop substitution is marked as a fallback")

        // Output with no tag must still work, so the function stays correct if
        // the script is ever replaced or bypassed.
        let untaggedResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "/Users/demo/Documents\n",
            stderr: ""
        )
        expect(untaggedResult.path == "/Users/demo/Documents", "untagged output is read as a plain path")
        expect(!untaggedResult.isFallback, "untagged output is not treated as a fallback")

        // A folder name may legally contain a newline on APFS, so only the
        // FIRST newline separates the tag from the path.
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "window\n/tmp/a\nb",
                stderr: ""
            ).path == "/tmp/a\nb",
            "only the first newline splits the tag from the path"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "window\n/tmp/trailing-newline\n\n",
                stderr: ""
            ).path == "/tmp/trailing-newline\n",
            "only osascript's final terminator is removed from a path ending in a newline"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "window\n/tmp/trailing-space \n",
                stderr: ""
            ).path == "/tmp/trailing-space ",
            "a legal trailing space in a folder name is preserved"
        )

        let stalledFinderResult = FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            )
        expect(
            stalledFinderResult.isFallback,
            "a stalled Finder is a fallback, never a recordable path"
        )
        expect(
            stalledFinderResult.failure == .timedOut,
            "a stalled Finder must be distinguishable from permission denial"
        )

        // Beginning a new Finder refresh must synchronously retire the previous
        // path. An older asynchronous completion may never make it actionable.
        var refreshState = FinderPathRefreshState()
        let firstRefresh = refreshState.begin()
        expect(refreshState.isRefreshing && refreshState.currentPath.isEmpty, "refresh begins in a loading state")
        expect(
            refreshState.complete(
                FinderPathQueryResult(path: "/tmp/old", isFallback: false),
                generation: firstRefresh
            ),
            "the active Finder refresh may complete"
        )
        expect(refreshState.currentPath == "/tmp/old", "a completed refresh exposes its path")
        let secondRefresh = refreshState.begin()
        expect(
            refreshState.currentPath.isEmpty && refreshState.isRefreshing,
            "starting another refresh immediately clears the stale actionable path"
        )
        expect(
            !refreshState.complete(
                FinderPathQueryResult(path: "/tmp/too-late", isFallback: false),
                generation: firstRefresh
            ),
            "an older Finder completion is rejected"
        )
        expect(refreshState.currentPath.isEmpty, "a rejected completion cannot revive the previous path")
        expect(
            refreshState.complete(
                FinderPathQueryResult(path: "/tmp/current", isFallback: false),
                generation: secondRefresh
            ),
            "the newest Finder completion wins"
        )
        expect(refreshState.currentPath == "/tmp/current", "the winning completion becomes actionable")

        let directoryTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathDirectoryTargetTests-\(UUID().uuidString)")
        let regularFileTarget = directoryTarget.appendingPathComponent("file")
        try? FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        try? Data([0x41]).write(to: regularFileTarget)
        let directoryValidation = await FinderPathDirectoryTarget.validate(directoryTarget.path)
        expect(
            directoryValidation == .available,
            "an existing action target directory is accepted"
        )
        let fileValidation = await FinderPathDirectoryTarget.validate(regularFileTarget.path)
        expect(
            fileValidation == .unavailable,
            "a regular file cannot become a terminal working directory"
        )
        try? FileManager.default.removeItem(at: directoryTarget)
        let deletedValidation = await FinderPathDirectoryTarget.validate(directoryTarget.path)
        expect(
            deletedValidation == .unavailable,
            "a deleted Recent Path is rejected at action time"
        )

        // Duplicate processes must elect one global winner using a total
        // ordering. This also gives URL forwarding an exact destination PID.
        let now = Date()
        let release = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.releaseBundleIdentifier,
            launchDate: now,
            processIdentifier: 400
        )
        let olderDevelopment = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.developmentBundleIdentifier,
            launchDate: now.addingTimeInterval(-60),
            processIdentifier: 100
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(olderDevelopment, over: release),
            "an already-running development build outranks a newer release"
        )
        let olderRelease = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.releaseBundleIdentifier,
            launchDate: now.addingTimeInterval(-1),
            processIdentifier: 900
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(olderRelease, over: release),
            "the older launch wins between builds with the same identity"
        )
        let unknownLaunchDate = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.releaseBundleIdentifier,
            launchDate: nil,
            processIdentifier: 1
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(unknownLaunchDate, over: release),
            "missing launch metadata conservatively represents an existing instance"
        )
        let currentWithoutLaunchDate = FinderPathInstanceIdentity.current(
            bundleIdentifier: FinderPathInstanceIdentity.releaseBundleIdentifier,
            observedLaunchDate: nil,
            processIdentifier: 1,
            fallbackLaunchDate: now
        )
        expect(
            currentWithoutLaunchDate.launchDate == now,
            "a current process with missing metadata is normalized to its known startup time"
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(olderDevelopment, over: currentWithoutLaunchDate),
            "missing current metadata cannot displace a known incumbent"
        )
        let simultaneousDevelopment = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.developmentBundleIdentifier,
            launchDate: now,
            processIdentifier: 1
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(release, over: simultaneousDevelopment),
            "release identity breaks an exact launch-time tie"
        )
        let lowerPID = FinderPathInstanceIdentity(
            bundleIdentifier: FinderPathInstanceIdentity.releaseBundleIdentifier,
            launchDate: now,
            processIdentifier: 399
        )
        expect(
            FinderPathInstanceIdentity.isPreferred(lowerPID, over: release),
            "PID deterministically breaks an exact launch-time tie"
        )
        expect(
            !FinderPathInstanceIdentity.isPreferred(release, over: release),
            "an instance never outranks itself"
        )

        // Recent Paths remembers the folders FinderPath saw. Order is recency,
        // so the list logic is pure and lives outside the @MainActor store.
        let visitDate = Date(timeIntervalSinceReferenceDate: 776_000_000)

        let seeded = RecentPathsLogic.recording("/tmp/one", into: [], at: visitDate)
        expect(seeded.map(\.path) == ["/tmp/one"], "recording seeds an empty list")

        let two = RecentPathsLogic.recording("/tmp/two", into: seeded, at: visitDate)
        expect(two.map(\.path) == ["/tmp/two", "/tmp/one"], "the newest path goes to the front")

        let promoted = RecentPathsLogic.recording("/tmp/one", into: two, at: visitDate)
        expect(promoted.map(\.path) == ["/tmp/one", "/tmp/two"], "revisiting promotes instead of duplicating")

        expect(
            RecentPathsLogic.recording("/tmp/one/", into: promoted, at: visitDate).count == 2,
            "a trailing slash is the same folder, not a second entry"
        )
        expect(
            RecentPathsLogic.recording("/tmp/trailing-space ", into: [], at: visitDate).first?.path
                == "/tmp/trailing-space ",
            "recording preserves a legal trailing space"
        )
        expect(
            RecentPathsLogic.recording("/tmp/trailing-newline\n", into: [], at: visitDate).first?.path
                == "/tmp/trailing-newline\n",
            "recording preserves a legal trailing newline"
        )
        expect(
            RecentPathsLogic.recording("/tmp/ignored", into: seeded, at: visitDate, limit: -1).isEmpty,
            "a defensive negative limit cannot trap"
        )

        // An error string is not a path and must never enter the history.
        expect(
            RecentPathsLogic.recording(
                FinderBridge.permissionDeniedMessage,
                into: seeded,
                at: visitDate
            ).count == 1,
            "an error message is never recorded as a path"
        )
        expect(
            RecentPathsLogic.recording("", into: seeded, at: visitDate).count == 1,
            "an empty path is ignored"
        )
        expect(
            RecentPathsLogic.recording("relative/path", into: seeded, at: visitDate).count == 1,
            "a relative path is ignored"
        )

        var capped: [RecentPath] = []
        for index in 0..<(RecentPathsLogic.limit + 2) {
            capped = RecentPathsLogic.recording("/tmp/folder\(index)", into: capped, at: visitDate)
        }
        expect(capped.count == RecentPathsLogic.limit, "the history is capped")
        expect(
            capped.first?.path == "/tmp/folder\(RecentPathsLogic.limit + 1)",
            "the newest entry survives the cap"
        )
        expect(!capped.contains { $0.path == "/tmp/folder0" }, "the oldest entry is dropped by the cap")

        // A bare folder name is ambiguous when two entries share it.
        let uniqueNames = [
            RecentPath(path: "/tmp/api", lastVisited: visitDate),
            RecentPath(path: "/tmp/web", lastVisited: visitDate)
        ]
        expect(
            RecentPathsLogic.menuTitles(for: uniqueNames) == ["api", "web"],
            "unique folder names stay bare"
        )

        let clashingNames = [
            RecentPath(path: "/tmp/api/src", lastVisited: visitDate),
            RecentPath(path: "/tmp/web/src", lastVisited: visitDate),
            RecentPath(path: "/tmp/docs", lastVisited: visitDate)
        ]
        expect(
            RecentPathsLogic.menuTitles(for: clashingNames) == ["api/src", "web/src", "docs"],
            "clashing names gain their parent on every occurrence, others stay bare"
        )

        expect(RecentPathsLogic.decode(Data("not json".utf8)).isEmpty, "corrupt history decodes to empty")
        expect(RecentPathsLogic.decode(Data()).isEmpty, "an empty file decodes to empty")
        expect(
            RecentPathsLogic.decode(RecentPathsLogic.encode(clashingNames)) == clashingNames,
            "history round-trips through the codec"
        )

        let oversizedHistory = (0..<(RecentPathsLogic.limit + 3)).map {
            RecentPath(path: "/tmp/history\($0)", lastVisited: visitDate)
        } + [
            RecentPath(path: "relative/history", lastVisited: visitDate),
            RecentPath(path: "/tmp/history0/", lastVisited: visitDate)
        ]
        let sanitizedHistory = RecentPathsLogic.decode(RecentPathsLogic.encode(oversizedHistory))
        expect(sanitizedHistory.count == RecentPathsLogic.limit, "decoded history is capped")
        expect(
            sanitizedHistory.allSatisfy { $0.path.hasPrefix("/") },
            "decoded history drops non-absolute entries"
        )
        expect(
            Set(sanitizedHistory.map(\.path)).count == sanitizedHistory.count,
            "decoded history removes standardized duplicates"
        )

        // MARK: - Pending URL queue
        //
        // AppKit delivers a launch URL before applicationDidFinishLaunching
        // finishes wiring up preferences and the action router, so URLs that
        // arrive early must be buffered and replayed rather than handled
        // against half-built state (or dropped, as they were before).

        var queue = PendingURLQueue()
        let connectURL = URL(string: "finderpath://connect")!
        let cmuxURL = URL(string: "finderpath://open-cmux")!

        expect(
            queue.accept([connectURL]).isEmpty,
            "URLs arriving before the app is ready are not handled immediately"
        )
        expect(!queue.isReady, "queue starts out not ready")

        expect(queue.accept([cmuxURL]).isEmpty, "a second early URL is also buffered")

        let drained = queue.drain()
        expect(drained == [connectURL, cmuxURL], "drain replays buffered URLs in arrival order")
        expect(queue.isReady, "drain marks the queue ready")
        expect(queue.drain().isEmpty, "draining twice does not replay URLs again")

        expect(
            queue.accept([connectURL]) == [connectURL],
            "once ready, URLs pass straight through"
        )

        // A malicious or stuck caller must not be able to grow the buffer
        // without bound while the app is still launching.
        var boundedQueue = PendingURLQueue()
        let flood = (0..<(PendingURLQueue.capacity + 25)).map {
            URL(string: "finderpath://connect?n=\($0)")!
        }
        expect(boundedQueue.accept(flood).isEmpty, "flood of early URLs is buffered, not handled")
        expect(
            boundedQueue.drain().count == PendingURLQueue.capacity,
            "early URL buffer is capped at PendingURLQueue.capacity"
        )
        expect(
            boundedQueue.accept(flood).count == PendingURLQueue.capacity,
            "a ready queue also bounds one forwarded URL batch"
        )

        // The queue is deliberately scheme-agnostic; FinderPathActionRouter
        // owns scheme validation, so nothing is silently discarded here.
        var passthroughQueue = PendingURLQueue()
        let foreignURL = URL(string: "https://example.com")!
        expect(passthroughQueue.accept([foreignURL]).isEmpty, "foreign URL is buffered like any other")
        expect(passthroughQueue.drain() == [foreignURL], "queue does not filter by scheme")

        if failures.isEmpty {
            print("FinderPath logic tests passed (\(assertionCount) assertions).")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(EXIT_FAILURE)
    }
}
