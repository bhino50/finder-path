import AppKit

enum FinderBridge {
    static func currentPath() -> String {
        // Some Finder windows, such as the Computer view, report a target that
        // cannot be coerced to a file alias. Treat those like no-window cases.
        let source = """
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
        """

        guard let script = NSAppleScript(source: source) else {
            return "Finder AppleScript error: Could not create the Finder query."
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? error.description
            return "Finder AppleScript error: \(message)"
        }

        if let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
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

        let quotedExecutable = ShellCommand.argument(commandName)
        let command = "if [[ -x \(quotedExecutable) ]]; then print -r -- \(quotedExecutable); else command -v -- \(quotedExecutable); fi"

        return AgentAvailability(
            executable: commandName,
            resolvedPath: shellOutput(for: command)
        )
    }

    // Async variant for UI-driven checks (Settings, in particular): the zsh
    // probe blocks on waitUntilExit, so run it on a background thread instead
    // of the caller's thread.
    static func checkAvailability(for executable: String, defaultExecutable: String? = nil) async -> AgentAvailability {
        await Task.detached {
            availability(for: executable, defaultExecutable: defaultExecutable)
        }.value
    }

    private static func shellOutput(for command: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]

        // GUI apps do not always inherit the user's interactive shell PATH, so
        // include the common Homebrew and local-bin locations used by CLI tools.
        var environment = ProcessInfo.processInfo.environment
        let commonPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(commonPath):\(environment["PATH"] ?? "")"
        task.environment = environment

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return output?.isEmpty == false ? output : nil
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
        task.standardOutput = Pipe()
        task.standardError = errorPipe

        // waitUntilExit blocks, so launch on a background task and report the
        // result asynchronously instead of stalling the caller's thread. The
        // completion may run off the main actor; callers hop back for UI work.
        Task.detached {
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                completion("Could not open Ghostty: \(error.localizedDescription)")
                return
            }

            if task.terminationStatus == 0 {
                completion(nil)
            } else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
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
        task.standardOutput = Pipe()
        task.standardError = Pipe()

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
        task.standardOutput = Pipe()
        task.standardError = errorPipe

        // Same pattern as openGhostty: never block the caller on waitUntilExit.
        Task.detached {
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                completion("Could not open Ghostty: \(error.localizedDescription)")
                return
            }

            if task.terminationStatus == 0 {
                completion(nil)
            } else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
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
        tell application "Terminal"
            activate
            do script "\(appleScriptString(command))"
        end tell
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
        tell application "Terminal"
            activate
            do script "\(appleScriptString(command))"
        end tell
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
