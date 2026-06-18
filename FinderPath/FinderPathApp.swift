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
    private var statusItemController: StatusItemController?
    private var welcomeWindowController: WelcomeWindowController?
    private let actionRouter = FinderPathActionRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FinderPathPreferences.registerDefaults()
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
            let path = FinderBridge.currentPath()
            guard !path.hasPrefix("Finder AppleScript error:") else {
                presentFailure(path, displayName: "Ghostty")
                return
            }

            TerminalBridge.openGhostty(at: path) { error in
                guard let error else { return }
                Task { @MainActor in
                    self.presentFailure(error, displayName: "Ghostty")
                }
            }
        case "open-cmux", "cmux":
            let path = FinderBridge.currentPath()
            guard !path.hasPrefix("Finder AppleScript error:") else {
                presentFailure(path, displayName: "cmux")
                return
            }

            TerminalBridge.openCmux(at: path) { error in
                guard let error else { return }
                Task { @MainActor in
                    self.presentFailure(error, displayName: "cmux")
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

    func refresh() {
        currentPath = FinderBridge.currentPath()
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

        TerminalBridge.open(at: currentPath) { _ in }
    }

    func openInGhostty() {
        guard hasCopyablePath else { return }

        TerminalBridge.openGhostty(at: currentPath) { _ in }
    }

    func openInCmux() {
        guard hasCopyablePath else { return }

        TerminalBridge.openCmux(at: currentPath) { _ in }
    }

    func openWithCodex() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.codexExecutable)
            .resolvedPath ?? FinderPathPreferences.codexExecutable

        TerminalBridge.openAgent(
            displayName: "Codex",
            executable: executable,
            at: currentPath
        ) { _ in }
    }

    func openWithClaude() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.claudeExecutable)
            .resolvedPath ?? FinderPathPreferences.claudeExecutable

        TerminalBridge.openAgent(
            displayName: "Claude",
            executable: executable,
            at: currentPath
        ) { _ in }
    }

    func openWithHermes() {
        guard hasCopyablePath else { return }

        let executable = AgentLauncher.availability(for: FinderPathPreferences.hermesExecutable)
            .resolvedPath ?? FinderPathPreferences.hermesExecutable

        TerminalBridge.openAgent(
            displayName: "Hermes",
            executable: executable,
            at: currentPath
        ) { _ in }
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
}
