import AppKit
import Darwin
import os

/// The outcome of one Finder query. `isFallback` is true whenever the path did
/// not come from a real Finder window — an error, a timeout, or the desktop
/// substitution the script makes when no window is open. Recent Paths records
/// only non-fallback results, so opening the menu without a Finder window does
/// not bury the history under repeated Desktop entries.
nonisolated struct FinderPathQueryResult: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case permissionDenied
        case timedOut
        case queryFailed
    }

    let path: String
    let isFallback: Bool
    let failure: Failure?

    init(path: String, isFallback: Bool, failure: Failure? = nil) {
        self.path = path
        self.isFallback = isFallback
        self.failure = failure
    }
}

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
    //
    // The answer is prefixed with a status line so the caller can tell a folder
    // the user actually had open ("window") from the desktop the script
    // substitutes when there is nothing open ("fallback"). Tagging only the
    // final desktop branch would not work: `insertion location` itself returns
    // the desktop when no window exists, so that branch is a fallback too.
    private static let pathQuerySource = """
    with timeout of 3 seconds
        tell application "Finder"
            set finderPath to missing value
            if (count of Finder windows) > 0 then
                try
                    set finderPath to POSIX path of (target of front Finder window as alias)
                end try
            end if
            if finderPath is not missing value then
                return "window" & linefeed & finderPath
            end if
            try
                set finderPath to POSIX path of (insertion location as alias)
            end try
            if finderPath is missing value then
                set finderPath to POSIX path of (path to desktop folder as alias)
            end if
            return "fallback" & linefeed & finderPath
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
    static func fetchCurrentPath() async -> FinderPathQueryResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executePathQuery())
            }
        }
    }

    private static func executePathQuery() -> FinderPathQueryResult {
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
            return FinderPathQueryResult(
                path: "Finder AppleScript error: \(error.localizedDescription)",
                isFallback: true,
                failure: .queryFailed
            )
        }

        // Terminating the child closes its pipe ends, so the reads below also
        // unblock when the watchdog fires.
        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        let forceKill = DispatchWorkItem {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        let watchdog = DispatchWorkItem {
            timedOutFlag.withLock { $0 = true }
            process.terminate()
            // SIGTERM should be enough for osascript, but a wedged child must
            // not turn an advertised eight-second timeout into an infinite one.
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 1, execute: forceKill)
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + queryTimeoutSeconds, execute: watchdog)

        // Drain both pipes concurrently. Reading stdout to EOF and only then
        // reading stderr can still deadlock when the child fills stderr while
        // the parent is waiting for stdout to close.
        let reads = DispatchGroup()
        let stdoutData = OSAllocatedUnfairLock(initialState: Data())
        let stderrData = OSAllocatedUnfairLock(initialState: Data())
        reads.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.withLock { $0 = data }
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData.withLock { $0 = data }
            reads.leave()
        }
        process.waitUntilExit()
        watchdog.cancel()
        forceKill.cancel()
        reads.wait()

        return interpretScriptResult(
            terminationStatus: process.terminationStatus,
            timedOut: timedOutFlag.withLock { $0 },
            stdout: String(decoding: stdoutData.withLock { $0 }, as: UTF8.self),
            stderr: String(decoding: stderrData.withLock { $0 }, as: UTF8.self)
        )
    }

    /// Maps an osascript run onto the path-or-error strings the UI expects.
    /// A successful path wins even when the watchdog raced the exit.
    static func interpretScriptResult(
        terminationStatus: Int32,
        timedOut: Bool,
        stdout: String,
        stderr: String
    ) -> FinderPathQueryResult {
        // osascript appends one record terminator to a returned string. Remove
        // exactly that terminator instead of trimming arbitrary whitespace:
        // spaces and newlines are legal characters at the end of APFS names.
        let output = removingProcessLineTerminator(from: stdout)
        if terminationStatus == 0, !output.isEmpty {
            let parsed = parseTaggedOutput(output)
            if !parsed.path.isEmpty {
                return parsed
            }
        }
        if timedOut {
            return FinderPathQueryResult(path: finderStalledMessage, isFallback: true, failure: .timedOut)
        }
        let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorText.contains(automationDeniedErrorCode) {
            return FinderPathQueryResult(
                path: permissionDeniedMessage,
                isFallback: true,
                failure: .permissionDenied
            )
        }
        if terminationStatus != 0 {
            let detail = errorText.isEmpty
                ? "The Finder query failed (status \(terminationStatus))."
                : errorText
            return FinderPathQueryResult(
                path: "Finder AppleScript error: \(detail)",
                isFallback: true,
                failure: .queryFailed
            )
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
            .first?
            .path ?? NSHomeDirectory()
        return FinderPathQueryResult(path: desktop, isFallback: true)
    }

    /// Splits the script's status line from the path. Only the FIRST newline
    /// separates them: a folder name may legally contain a newline on APFS, and
    /// splitting on every newline would truncate such a path. Output carrying no
    /// recognized tag is read as a plain path so this stays correct if the
    /// script is ever replaced or bypassed.
    private static func parseTaggedOutput(_ output: String) -> FinderPathQueryResult {
        guard let newline = output.firstIndex(of: "\n") else {
            return FinderPathQueryResult(path: output, isFallback: false)
        }
        let path = String(output[output.index(after: newline)...])
        switch output[..<newline] {
        case "window":
            return FinderPathQueryResult(path: path, isFallback: false)
        case "fallback":
            return FinderPathQueryResult(path: path, isFallback: true)
        default:
            return FinderPathQueryResult(path: output, isFallback: false)
        }
    }

    private static func removingProcessLineTerminator(from output: String) -> String {
        if output.hasSuffix("\r\n") {
            return String(output.dropLast(2))
        }
        if output.hasSuffix("\n") {
            return String(output.dropLast())
        }
        return output
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
    struct MenuPresentation: Equatable {
        let title: String
        let usesBuiltInTerminal: Bool
    }

    /// Menus presented with `NSMenu.popUp` do not reliably perform AppKit's
    /// live alternate-item swap. Choose the visible row while building the
    /// menu instead, using the modifier state captured from the status click.
    static func menuPresentation(name: String, optionHeld: Bool) -> MenuPresentation {
        MenuPresentation(
            title: optionHeld
                ? "Open with \(name) in FinderPath Terminal"
                : "Open with \(name)",
            usesBuiltInTerminal: optionHeld
        )
    }

    /// `isExecutableFile(atPath:)` is true for any searchable directory, so a
    /// folder named `claude` on PATH reported the agent as installed and then
    /// failed at launch. Only a regular file with the execute bit counts.
    static func isExecutableRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

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
                resolvedPath: isExecutableRegularFile(atPath: path) ? path : nil
            )
        }

        let resolvedPath = executableSearchDirectories()
            .lazy
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(commandName).path }
            .first { isExecutableRegularFile(atPath: $0) }

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

        return AgentLauncher.isExecutableRegularFile(atPath: cmuxBundleExecutablePath)
            ? cmuxBundleExecutablePath
            : nil
    }

    static func open(at path: String, completion: @escaping (String?) -> Void) {
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)

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
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)

        guard let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) else {
            completion("Ghostty.app was not found.")
            return
        }

        // Ghostty declares public.directory as a document type, so opening the
        // folder as a document opens a terminal window at that directory in
        // the already-running instance. The previous
        // `open -n --args --working-directory=...` launch spawned a whole
        // second Ghostty instance (duplicate Dock icon and window management)
        // whenever Ghostty was already running.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open([directoryURL], withApplicationAt: ghosttyURL, configuration: configuration) { _, error in
            if let error {
                completion("Could not open Ghostty: \(error.localizedDescription)")
            } else {
                completion(nil)
            }
        }
    }

    static func openCmux(at path: String, completion: @escaping (String?) -> Void) {
        let directoryPath = URL(fileURLWithPath: path, isDirectory: true).path

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

    private static let sshScriptDirectoryPrefix = "FinderPathSSH-"
    /// Long enough for Ghostty to have opened and read the script. Deleting it
    /// from inside the script would race `sh`, which reads the file as it runs.
    private static let sshScriptLifetime: TimeInterval = 20
    private static let sshScriptStaleAge: TimeInterval = 300

    /// Body of the throwaway script Ghostty opens as a document. Split out so
    /// the logic tests can assert the host stays shell-quoted.
    static func sshLaunchScriptSource(host: String) -> String {
        """
        #!/bin/sh
        exec ssh -- \(ShellCommand.argument(host))
        """
    }

    private static func openSSHInGhostty(host: String, completion: @escaping (String?) -> Void) {
        guard let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) else {
            completion("Ghostty.app was not found. Choose a different SSH terminal in Settings.")
            return
        }

        let script: URL
        do {
            script = try writeSSHLaunchScript(host: host)
        } catch {
            completion("Could not prepare the SSH session: \(error.localizedDescription)")
            return
        }

        // `open -n ... --args -e ssh` was the only documented way to hand
        // Ghostty a command on macOS, but -n always spawns a second Ghostty
        // process (verified: instance count goes 1 -> 2) — the same duplicate
        // instance openGhostty was fixed for. Ghostty also declares shell
        // scripts as a document type, so opening one runs it in the instance
        // that is already up, exactly like the folder path above. Ghostty's
        // +new-window action would be tidier but is Linux-only.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open([script], withApplicationAt: ghosttyURL, configuration: configuration) { _, error in
            scheduleSSHScriptCleanup(at: script.deletingLastPathComponent())
            if let error {
                completion("Could not open Ghostty: \(error.localizedDescription)")
            } else {
                completion(nil)
            }
        }
    }

    /// Writes the launch script into a private per-launch directory. The host
    /// is already validated by openSSH and is shell-quoted into the body, so
    /// the script cannot run anything but ssh against that host.
    private static func writeSSHLaunchScript(host: String) throws -> URL {
        removeStaleSSHScriptDirectories()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(sshScriptDirectoryPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // `.command` is one of Ghostty's declared terminal-script extensions.
        let script = directory.appendingPathComponent("ssh.command")
        try sshLaunchScriptSource(host: host).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private static func scheduleSSHScriptCleanup(at directory: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sshScriptLifetime) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A crash or a forced quit between writing and cleanup would strand a
    /// script, so each launch also sweeps directories older than the stale age.
    private static func removeStaleSSHScriptDirectories() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-sshScriptStaleAge)
        for entry in entries where entry.lastPathComponent.hasPrefix(sshScriptDirectoryPrefix) {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified <= cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func openSSHInTerminal(host: String, completion: @escaping (String?) -> Void) {
        // Terminal runs the command through a shell, so the host must be quoted.
        // `--` ends ssh option parsing so a leading-dash host can't act as a flag.
        let command = "ssh -- \(ShellCommand.argument(host))"
        runTerminalScript(command: command, completion: completion)
    }

    /// Runs a `do script` against Terminal.app without blocking the caller.
    ///
    /// NSAppleScript is main-thread-only and `executeAndReturnError` blocks for
    /// the whole Apple event round trip — which includes Terminal.app's cold
    /// launch and the TCC Automation consent prompt, and that prompt waits on
    /// the user indefinitely. Every caller is main-actor isolated, so this
    /// froze the entire app, including PTY rendering in every open built-in
    /// terminal. Running osascript in a subprocess off the main thread is the
    /// same approach FinderBridge.fetchCurrentPath already uses, for the same
    /// reason. The completion may run off the main actor, matching the
    /// contract openGhostty/openSSHInGhostty already have.
    /// Builds the AppleScript that runs `command` in Terminal.app.
    ///
    /// Terminal launched cold by an Apple event still opens its startup window
    /// before servicing `do script`, so an unconditional `do script` produced
    /// two windows per launch: the idle startup window plus the command
    /// window. The running state is read outside the tell block — the first
    /// event inside it would launch Terminal and hide whether the startup
    /// window is fresh — and a cold launch reuses window 1, falling back to a
    /// new window when Terminal is configured to start without one. The
    /// timeout is generous because a cold launch (or the TCC consent prompt)
    /// can exceed a few seconds, and a premature -1712 surfaced as a spurious
    /// launch-failure alert while the window went on to open anyway.
    static func terminalLaunchScriptSource(command: String) -> String {
        """
        set launchCommand to "\(escapedAppleScriptString(command))"
        set terminalWasRunning to application id "com.apple.Terminal" is running
        with timeout of 30 seconds
            tell application id "com.apple.Terminal"
                if terminalWasRunning then
                    do script launchCommand
                else
                    try
                        do script launchCommand in window 1
                    on error
                        do script launchCommand
                    end try
                end if
                activate
            end tell
        end timeout
        """
    }

    private static func runTerminalScript(
        command: String,
        completion: @escaping (String?) -> Void
    ) {
        let source = terminalLaunchScriptSource(command: command)

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                completion("Could not run the Terminal launch script: \(error.localizedDescription)")
                return
            }

            // Drain before waiting so a full pipe buffer cannot deadlock exit.
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else {
                completion(nil)
                return
            }
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion("Terminal AppleScript error: \(detail.isEmpty ? "the script failed." : detail)")
        }
    }

    static func openAgent(
        displayName: String,
        executable: String,
        at path: String,
        completion: @escaping (String?) -> Void
    ) {
        let directoryPath = URL(fileURLWithPath: path, isDirectory: true).path
        let executableArgument = ShellCommand.argument(executable)
        let missingMessage = "\(displayName) CLI was not found. Install it or add \(executable) to your shell PATH."
        let command = """
        clear; cd \(ShellCommand.argument(directoryPath)) && if command -v -- \(executableArgument) >/dev/null 2>&1; then exec \(executableArgument); else echo \(ShellCommand.argument(missingMessage)); exec ${SHELL:-/bin/zsh} -l; fi
        """

        // Terminal can open a folder through NSWorkspace, but running a CLI
        // command in a new tab/window requires Terminal's AppleScript interface.
        runTerminalScript(command: command, completion: completion)
    }

    /// AppleScript string literals cannot span raw newlines, but they do
    /// understand `\n` and `\r` escapes. Replacing the characters with spaces
    /// (as this used to) silently rewrote the command: a folder whose name
    /// contains a newline — legal on APFS — turned `cd '/tmp/a<LF>b'` into
    /// `cd '/tmp/a b'`, so the launch landed in the wrong directory or failed.
    /// Emitting the escape preserves the byte. Backslash is escaped first so
    /// the escapes added below are not themselves doubled.
    static func escapedAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
