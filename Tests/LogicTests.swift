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
                == "one two \\\"three\\\"\\\\four",
            "Terminal AppleScript strings should neutralize CR, LF, quotes, and backslashes"
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
            ) == "/Users/demo/Documents",
            "successful query should return the trimmed path"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: true,
                stdout: "/tmp\n",
                stderr: ""
            ) == "/tmp",
            "a completed query should win over a racing timeout"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)"
            ) == FinderBridge.permissionDeniedMessage,
            "automation denial should map to the permission message"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            ) == FinderBridge.finderStalledMessage,
            "a watchdog kill should report Finder as not responding"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Finder got an error: AppleEvent timed out. (-1712)"
            ).hasPrefix("Finder AppleScript error:"),
            "other script failures should surface as error strings"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "",
                stderr: ""
            ).hasPrefix("/"),
            "empty output should fall back to a local folder"
        )

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
