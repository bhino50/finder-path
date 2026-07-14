import SwiftUI
import AppKit

@main
struct FinderPathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let releaseBundleIdentifier = "io.github.bhino50.FinderPath"
    private static let developmentBundleIdentifier = "io.github.bhino50.FinderPathDev"
    private static let finderPathBundleIdentifiers: Set<String> = [
        releaseBundleIdentifier,
        developmentBundleIdentifier,
    ]

    private var statusItemController: StatusItemController?
    private var welcomeWindowController: WelcomeWindowController?
    private let actionRouter = FinderPathActionRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services normally reuses a running app, but development builds,
        // `open -n`, or stale FinderPathDev bundles can still start a second
        // process. Refuse every FinderPath-owned bundle before it creates another
        // status item or races the shared terminal-session metadata file.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let existingApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard application.processIdentifier != currentPID else { return false }
            if Self.finderPathBundleIdentifiers.contains(application.bundleIdentifier ?? "") {
                return true
            }
            return application.bundleURL?.pathExtension.lowercased() == "app"
                && application.executableURL?.lastPathComponent == "FinderPath"
        }

        // The official app owns the production identity. If an old development
        // bundle was left running, ask it to quit and continue launching the
        // official build instead of sending the user back to stale code.
        if currentBundleIdentifier == Self.releaseBundleIdentifier {
            for developmentApp in existingApplications
                where developmentApp.bundleIdentifier == Self.developmentBundleIdentifier {
                developmentApp.terminate()
            }
        }

        if let existing = existingApplications.first(where: { application in
            if currentBundleIdentifier == Self.releaseBundleIdentifier {
                return application.bundleIdentifier != Self.developmentBundleIdentifier
            }
            return true
        }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }

        FinderPathPreferences.registerDefaults()
        // Feed shell and scrollback preferences into every session the store
        // creates or restores. Resolved lazily so preference edits during the
        // session take effect on the next new terminal.
        TerminalSessionStore.shared.configurationProvider = {
            let override = FinderPathPreferences.terminalShellOverride.trimmingCharacters(in: .whitespaces)
            let usesOverride = !override.isEmpty && FileManager.default.isExecutableFile(atPath: override)
            return TerminalSessionConfiguration(
                shellPath: usesOverride ? override : PTYProcess.defaultShell(),
                scrollbackLimit: FinderPathPreferences.terminalScrollbackLimit
            )
        }
        // Restore stored terminal sessions (metadata only; shells relaunch
        // lazily) before the menu builds so the Terminals section is complete.
        TerminalSessionStore.shared.loadPersistedSessions()
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
        statusItemController?.onOpenWelcomeGuide = { [weak self] in
            self?.showWelcomeGuide()
        }
        if !FinderPathPreferences.completedWelcome {
            showWelcomeGuide()
        }
        actionRouter.onOpenConnectWindow = { [weak self] in
            self?.statusItemController?.openRemoteConnectionWindow()
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Shells do not outlive the app; session metadata stays persisted.
        TerminalSessionStore.shared.terminateAll()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        actionRouter.handle(url: url)
    }

    func showWelcomeGuide() {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindowController?.presentOnActiveScreen()
    }
}

@MainActor
final class FinderPathActionRouter {
    var onOpenConnectWindow: (() -> Void)?

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "finderpath" else { return }

        switch actionName(for: url) {
        case "connect", "connect-to-server":
            onOpenConnectWindow?()
        case "open-ghostty", "ghostty":
            Task { @MainActor in
                let path = await FinderBridge.fetchCurrentPath()
                guard !path.hasPrefix("Finder AppleScript error:") else {
                    self.presentFailure(path, displayName: "Ghostty")
                    return
                }

                TerminalBridge.openGhostty(at: path) { error in
                    guard let error else { return }
                    Task { @MainActor in
                        self.presentFailure(error, displayName: "Ghostty")
                    }
                }
            }
        case "open-cmux", "cmux":
            Task { @MainActor in
                let path = await FinderBridge.fetchCurrentPath()
                guard !path.hasPrefix("Finder AppleScript error:") else {
                    self.presentFailure(path, displayName: "cmux")
                    return
                }

                TerminalBridge.openCmux(at: path) { error in
                    guard let error else { return }
                    Task { @MainActor in
                        self.presentFailure(error, displayName: "cmux")
                    }
                }
            }
        default:
            break
        }
    }

    private func actionName(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            return host.lowercased()
        }

        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func presentFailure(_ message: String, displayName: String) {
        FinderPathAlertPresenter.presentLaunchFailure(message, displayName: displayName)
    }
}

@MainActor
enum FinderPathAlertPresenter {
    static func presentLaunchFailure(_ message: String, displayName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "FinderPath could not open \(displayName)."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class FinderPathState {
    var currentPath = ""
    private var refreshGeneration = 0

    /// Fetches the Finder path off the main thread and reports back on the
    /// main actor, so a stalled Finder can never beachball the app. Stale
    /// completions from an earlier refresh are dropped.
    func refresh(onChange: (() -> Void)? = nil) {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task { @MainActor [weak self] in
            let path = await FinderBridge.fetchCurrentPath()
            guard let self, generation == self.refreshGeneration else { return }
            self.currentPath = path
            onChange?()
        }
    }

    func copyCurrentPath() {
        guard hasCopyablePath else { return }

        copyToPasteboard(currentPath)
    }

    func copyChangeDirectoryCommand() {
        guard hasCopyablePath else { return }

        copyToPasteboard("cd \(ShellCommand.argument(currentPath, quoteStyle: FinderPathPreferences.cdQuoteStyle))")
    }

    func openInTerminal() {
        guard hasCopyablePath else { return }

        TerminalBridge.open(at: currentPath) { error in
            self.presentLaunchFailure(error, displayName: "Terminal")
        }
    }

    func openInGhostty() {
        guard hasCopyablePath else { return }

        TerminalBridge.openGhostty(at: currentPath) { error in
            self.presentLaunchFailure(error, displayName: "Ghostty")
        }
    }

    func openInCmux() {
        guard hasCopyablePath else { return }

        TerminalBridge.openCmux(at: currentPath) { error in
            self.presentLaunchFailure(error, displayName: "cmux")
        }
    }

    func openWithCodex() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.codexExecutable)
            .resolvedPath ?? FinderPathPreferences.codexExecutable

        TerminalBridge.openAgent(
            displayName: "Codex",
            executable: executable,
            at: currentPath
        ) { error in
            self.presentLaunchFailure(error, displayName: "Codex")
        }
    }

    func openWithClaude() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.claudeExecutable)
            .resolvedPath ?? FinderPathPreferences.claudeExecutable

        TerminalBridge.openAgent(
            displayName: "Claude",
            executable: executable,
            at: currentPath
        ) { error in
            self.presentLaunchFailure(error, displayName: "Claude")
        }
    }

    func openWithHermes() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.hermesExecutable)
            .resolvedPath ?? FinderPathPreferences.hermesExecutable

        TerminalBridge.openAgent(
            displayName: "Hermes",
            executable: executable,
            at: currentPath
        ) { error in
            self.presentLaunchFailure(error, displayName: "Hermes")
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        let currentVersion = AppVersion.current
        UpdateChecker.check(manifestURL: FinderPathPreferences.updateManifestURL) { result in
            Task { @MainActor in
                UpdatePrompt.present(
                    result: result,
                    currentVersion: currentVersion,
                    userInitiated: userInitiated
                )
            }
        }
    }

    var hasCopyablePath: Bool {
        !currentPath.isEmpty && !currentPath.hasPrefix("Finder AppleScript error:")
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func presentLaunchFailure(_ message: String?, displayName: String) {
        guard let message else { return }

        Task { @MainActor in
            FinderPathAlertPresenter.presentLaunchFailure(message, displayName: displayName)
        }
    }
}
