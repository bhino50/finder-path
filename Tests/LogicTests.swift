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

        expect(ShellCommand.argument("it's here") == "'it'\\''s here'", "single-quote escaping should be shell-safe")
        expect(
            ShellCommand.argument("$HOME/`pwd`/\"folder\"", quoteStyle: "double")
                == "\"\\$HOME/\\`pwd\\`/\\\"folder\\\"\"",
            "double-quote escaping should protect substitutions"
        )

        expect(AgentLauncher.availability(for: "/bin/sh").resolvedPath == "/bin/sh", "absolute executables should resolve")
        expect(AgentLauncher.availability(for: "sh").isInstalled, "PATH executables should resolve")
        expect(!AgentLauncher.availability(for: "finderpath-command-that-does-not-exist").isInstalled, "missing executables should not resolve")

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
