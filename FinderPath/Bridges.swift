import AppKit
import os

nonisolated enum FinderBridge {
    // AppleScript error -1743 (errAEEventNotPermitted): the user declined the
    // Automation prompt, or FinderPath was switched off later under
    // System Settings > Privacy & Security > Automation. osascript prints the
    // code in parentheses at the end of its stderr line.
    private static let automationDeniedErrorCode = "(-1743)"

    static let permissionDeniedMessage = "Finder AppleScript error: FinderPath is not allowed to control Finder."

    static let finderStalledMessage = "Finder AppleScript error: Finder is not responding."

    static let automationSettingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    // The script's own AppleEvent timeout is 3 seconds, but a stalled Finder
    // can burn that per Apple event; the watchdog is the hard upper bound.
    private static let queryTimeoutSeconds: TimeInterval = 8

    // Some Finder windows, such as the Computer view, report a target that
    // cannot be coerced to a file alias. Treat those like no-window cases.
    private static let pathQuerySource = """
    with timeout of 3 seconds
        tell application "Finder"
            set finderPath to missing value
            if (count of Finder windows) > 0 then
                try
                    set finderPath to POSIX path of (target of front Finder window as alias)
                end try
            end if
            if finderPath is missing value then
                try
                    set finderPath to POSIX path of (insertion location as alias)
                end try
            end if
            if finderPath is missing value then
                return POSIX path of (path to desktop folder as alias)
            end if
            return finderPath
        end tell
    end timeout
    """

    static func isPermissionDenied(_ path: String) -> Bool {
        path == permissionDeniedMessage
    }

    static func openAutomationSettings() {
        guard let url = URL(string: automationSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Asks Finder for the front window's path without ever blocking the main
    /// thread. The AppleScript runs in an osascript subprocess (NSAppleScript
    /// is main-thread-only) on a background queue, and a watchdog kills the
    /// query when Finder is beachballed — e.g. by a stalled network volume.
    static func fetchCurrentPath() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executePathQuery())
            }
        }
    }

    private static func executePathQuery() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", pathQuerySource]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return "Finder AppleScript error: \(error.localizedDescription)"
        }

        // Terminating the child closes its pipe ends, so the reads below also
        // unblock when the watchdog fires.
        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            timedOutFlag.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + queryTimeoutSeconds, execute: watchdog)

        // Drain both pipes before waiting so a full pipe buffer can never
        // deadlock against process exit.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return interpretScriptResult(
            terminationStatus: process.terminationStatus,
            timedOut: timedOutFlag.withLock { $0 },
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// Maps an osascript run onto the path-or-error strings the UI expects.
    /// A successful path wins even when the watchdog raced the exit.
    static func interpretScriptResult(
        terminationStatus: Int32,
        timedOut: Bool,
        stdout: String,
        stderr: String
    ) -> String {
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminationStatus == 0, !path.isEmpty {
            return path
        }
        if timedOut {
            return finderStalledMessage
        }
        let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorText.contains(automationDeniedErrorCode) {
            return permissionDeniedMessage
        }
        if terminationStatus != 0 {
            let detail = errorText.isEmpty
                ? "The Finder query failed (status \(terminationStatus))."
                : errorText
            return "Finder AppleScript error: \(detail)"
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
            .first?
            .path ?? NSHomeDirectory()
    }
}

struct AgentAvailability: Equatable, Sendable {
    let executable: String
    let resolvedPath: String?

    var isInstalled: Bool {
        resolvedPath != nil
    }

    static func unknown(executable: String) -> AgentAvailability {
        AgentAvailability(executable: executable, resolvedPath: nil)
    }
}

nonisolated enum AgentLauncher {
    static func availability(for executable: String, defaultExecutable: String? = nil) -> AgentAvailability {
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandName = trimmedExecutable.isEmpty ? (defaultExecutable ?? "") : trimmedExecutable
        guard !commandName.isEmpty else {
            return AgentAvailability(executable: executable, resolvedPath: nil)
        }

        let expandedCommand = NSString(string: commandName).expandingTildeInPath
        if expandedCommand.contains("/") {
            let path = URL(fileURLWithPath: expandedCommand).standardizedFileURL.path
            return AgentAvailability(
                executable: commandName,
                resolvedPath: FileManager.default.isExecutableFile(atPath: path) ? path : nil
            )
        }

        let resolvedPath = executableSearchDirectories()
            .lazy
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(commandName).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        return AgentAvailability(
            executable: commandName,
            resolvedPath: resolvedPath
        )
    }

    // Retain an async API for UI call sites. Resolution is now a fast filesystem
    // lookup rather than a login-shell subprocess, so opening the menu cannot be
    // delayed by shell startup files or a stuck command probe.
    static func checkAvailability(for executable: String, defaultExecutable: String? = nil) async -> AgentAvailability {
        availability(for: executable, defaultExecutable: defaultExecutable)
    }

    private static func executableSearchDirectories() -> [String] {
        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inheritedDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        var seen = Set<String>()
        return (commonDirectories + inheritedDirectories).filter { seen.insert($0).inserted }
    }
}

enum TerminalBridge {
    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    static let cmuxBundleExecutablePath = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    static var isGhosttyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) != nil
    }

    static var isCmuxInstalled: Bool {
        cmuxExecutablePath() != nil
    }

    // cmux is a Ghostty-based workspace manager. Its CLI may live on the user's
    // shell PATH or only inside the app bundle, so check both.
    static func cmuxExecutablePath() -> String? {
        if let resolved = AgentLauncher.availability(for: "cmux", defaultExecutable: "cmux").resolvedPath {
            return resolved
        }

        return FileManager.default.isExecutableFile(atPath: cmuxBundleExecutablePath) ? cmuxBundleExecutablePath : nil
    }

    static func open(at path: String, completion: @escaping (String?) -> Void) {
        let directoryURL = resolvedDirectoryURL(for: path)

        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            completion("Terminal.app was not found.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open([directoryURL], withApplicationAt: terminalURL, configuration: configuration) { _, error in
            if let error {
                completion("Could not open Terminal: \(error.localizedDescription)")
            } else {
                completion(nil)
            }
        }
    }

    static func openGhostty(at path: String, completion: @escaping (String?) -> Void) {
        let directoryURL = resolvedDirectoryURL(for: path)

        guard let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) else {
            completion("Ghostty.app was not found.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [
            "-n",
            ghosttyURL.path,
            "--args",
            "--working-directory=\(directoryURL.path)",
            "--window-inherit-working-directory=false",
            "--tab-inherit-working-directory=false"
        ]

        let errorPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorPipe

        // waitUntilExit blocks, so launch on a background task and report the
        // result asynchronously instead of stalling the caller's thread. The
        // completion may run off the main actor; callers hop back for UI work.
        Task.detached {
            do {
                try task.run()
            } catch {
                completion("Could not open Ghostty: \(error.localizedDescription)")
                return
            }

            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                completion(nil)
            } else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(message?.isEmpty == false ? message : "Could not open Ghostty.")
            }
        }
    }

    static func openCmux(at path: String, completion: @escaping (String?) -> Void) {
        let directoryPath = resolvedDirectoryURL(for: path).path

        guard let cmuxPath = cmuxExecutablePath() else {
            completion("cmux CLI was not found. Install cmux or add it to your shell PATH.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cmuxPath)
        task.arguments = [directoryPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            completion(nil)
        } catch {
            completion("Could not open cmux: \(error.localizedDescription)")
        }
    }

    // Terminals that can host a remote SSH session. cmux is intentionally absent:
    // its CLI opens directories, not arbitrary commands, so it cannot run ssh.
    enum RemoteTerminal: String {
        case ghostty
        case terminal
    }

    static func openSSH(host: String, using terminal: RemoteTerminal, completion: @escaping (String?) -> Void) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            completion("No server host was provided.")
            return
        }

        // Reject hosts that look like an option so a value such as
        // "-oProxyCommand=..." can't be smuggled in as an ssh flag (argv flag
        // injection / remote command execution). Both backends also pass `--`.
        guard !trimmedHost.hasPrefix("-") else {
            completion("Refusing to connect to a host that starts with '-' (possible SSH flag injection).")
            return
        }

        guard trimmedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            completion("Enter just the SSH host or user@host, without the ssh command or extra options.")
            return
        }

        switch terminal {
        case .ghostty:
            openSSHInGhostty(host: trimmedHost, completion: completion)
        case .terminal:
            openSSHInTerminal(host: trimmedHost, completion: completion)
        }
    }

    private static func openSSHInGhostty(host: String, completion: @escaping (String?) -> Void) {
        guard let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) else {
            completion("Ghostty.app was not found. Choose a different SSH terminal in Settings.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Ghostty runs `-e <command>` directly without a shell, so the host is
        // passed as its own argument and needs no shell quoting. `--` ends ssh
        // option parsing so the host is always treated as a positional argument.
        task.arguments = ["-n", ghosttyURL.path, "--args", "-e", "ssh", "--", host]

        let errorPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorPipe

        // Same pattern as openGhostty: never block the caller on waitUntilExit.
        Task.detached {
            do {
                try task.run()
            } catch {
                completion("Could not open Ghostty: \(error.localizedDescription)")
                return
            }

            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                completion(nil)
            } else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(message?.isEmpty == false ? message : "Could not start the SSH session in Ghostty.")
            }
        }
    }

    private static func openSSHInTerminal(host: String, completion: @escaping (String?) -> Void) {
        // Terminal runs the command through a shell, so the host must be quoted.
        // `--` ends ssh option parsing so a leading-dash host can't act as a flag.
        let command = "ssh -- \(ShellCommand.argument(host))"
        let source = """
        with timeout of 3 seconds
            tell application "Terminal"
                activate
                do script "\(appleScriptString(command))"
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            completion("Could not create the Terminal launch script.")
            return
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? error.description
            completion("Terminal AppleScript error: \(message)")
        } else {
            completion(nil)
        }
    }

    static func openAgent(
        displayName: String,
        executable: String,
        at path: String,
        completion: @escaping (String?) -> Void
    ) {
        let directoryPath = resolvedDirectoryURL(for: path).path
        let executableArgument = ShellCommand.argument(executable)
        let missingMessage = "\(displayName) CLI was not found. Install it or add \(executable) to your shell PATH."
        let command = """
        clear; cd \(ShellCommand.argument(directoryPath)) && if command -v -- \(executableArgument) >/dev/null 2>&1; then exec \(executableArgument); else echo \(ShellCommand.argument(missingMessage)); exec ${SHELL:-/bin/zsh} -l; fi
        """

        // Terminal can open a folder through NSWorkspace, but running a CLI
        // command in a new tab/window requires Terminal's AppleScript interface.
        let source = """
        with timeout of 3 seconds
            tell application "Terminal"
                activate
                do script "\(appleScriptString(command))"
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: source) else {
            completion("Could not create the Terminal launch script.")
            return
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? error.description
            completion("Terminal AppleScript error: \(message)")
        } else {
            completion(nil)
        }
    }

    private static func resolvedDirectoryURL(for path: String) -> URL {
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
