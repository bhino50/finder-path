import Darwin
import Foundation

@main
struct FinderPathLogicTests {
    static func main() {
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
        // Ordering deliberately keeps ignoring suffixes.
        expect(UpdateChecker.compare("1.8-beta", isNewerThan: "1.7"), "ordering still ignores prerelease suffixes")

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
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Finder got an error: AppleEvent timed out. (-1712)"
            ).path.hasPrefix("Finder AppleScript error:"),
            "other script failures should surface as error strings"
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

        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            ).isFallback,
            "a stalled Finder is a fallback, never a recordable path"
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
