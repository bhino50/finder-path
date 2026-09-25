import Foundation

/// The text FinderPath hands to Terminal.app: a shell command line, wrapped
/// in the AppleScript that makes Terminal type it into a new window.
extension TerminalBridge {
    /// Terminal types an agent launch into the user's login shell, which may
    /// be fish or tcsh rather than a POSIX shell. The typed line therefore
    /// only starts /bin/sh with quoted arguments, and this fixed program holds
    /// all the control flow. $1 is the folder, $2 the resolved executable and
    /// $3 the message shown if it vanished after the menu checked it. `exec`
    /// hands the window to the agent, so the session ends when the agent
    /// exits; a missing folder or agent leaves a fresh login shell instead.
    /// The program has no quote, backslash, or bang, so it stays one readable
    /// single-quoted word; that is why the message ends with a bare `echo`.
    static let agentLaunchScript = """
        clear; cd -- "$1" || exec "${SHELL:-/bin/zsh}" -l; \
        if command -v -- "$2" >/dev/null 2>&1; then exec "$2"; fi; \
        printf "%s" "$3"; echo; exec "${SHELL:-/bin/zsh}" -l
        """

    /// `executable` is the absolute path the menu resolved, so the message
    /// names that path and the Settings field that chose it.
    static func agentMissingMessage(displayName: String, executable: String) -> String {
        "\(displayName) CLI was not found at \(executable). Check its command or path in FinderPath Settings."
    }

    /// Everything outside the quoted arguments is plain words, so the line
    /// parses the same way in sh, bash, zsh, fish, and tcsh.
    static func agentLaunchCommand(displayName: String, executable: String, directoryPath: String) -> String {
        let arguments = [
            agentLaunchScript,
            "FinderPath",
            directoryPath,
            executable,
            agentMissingMessage(displayName: displayName, executable: executable)
        ]
        return (["exec", "/bin/sh", "-c"] + arguments.map(ShellCommand.portableArgument))
            .joined(separator: " ")
    }

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
