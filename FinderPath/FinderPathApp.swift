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
    private let actionRouter = FinderPathActionRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FinderPathPreferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
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

@MainActor
final class StatusItemController: NSObject {
    private let state = FinderPathState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindowController: SettingsWindowController?
    private var remoteConnectionWindowController: RemoteConnectionWindowController?

    override init() {
        super.init()

        // NSStatusItem keeps FinderPath as a lightweight native menu bar utility
        // while allowing custom click timing so the menu does not drag with the cursor.
        if let button = statusItem.button {
            button.toolTip = "FinderPath"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusItemAppearance()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        state.refresh()
        rebuildMenu(menu)
        sender.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        sender.highlight(false)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        if FinderPathPreferences.showPathHeader {
            let pathItem = NSMenuItem()
            pathItem.view = PathMenuHeaderView(
                path: FinderPathPreferences.displayPath(for: state.currentPath),
                isError: !state.hasCopyablePath
            )
            menu.addItem(pathItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsMenuItem), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        if FinderPathPreferences.showRefreshItem {
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshMenuItem), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)
        }

        if FinderPathPreferences.showCopyPathItem {
            let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathMenuItem), keyEquivalent: "")
            copyItem.target = self
            copyItem.isEnabled = state.hasCopyablePath
            menu.addItem(copyItem)
        }

        if FinderPathPreferences.showCopyCDItem {
            let copyCDItem = NSMenuItem(title: "Copy cd Command", action: #selector(copyCDMenuItem), keyEquivalent: "")
            copyCDItem.target = self
            copyCDItem.isEnabled = state.hasCopyablePath
            menu.addItem(copyCDItem)
        }

        let hideUnavailableAgents = FinderPathPreferences.hideUnavailableAgentItems
        var didAddPrimaryLauncher = false
        var pendingLauncherSeparator = false

        // Insert a single separator between the primary launchers (cmux, Ghostty)
        // and the secondary ones, but only once a secondary item is actually shown.
        func addPendingLauncherSeparator() {
            if pendingLauncherSeparator {
                menu.addItem(.separator())
                pendingLauncherSeparator = false
            }
        }

        if FinderPathPreferences.showOpenCmuxItem {
            let isInstalled = TerminalBridge.isCmuxInstalled
            if !hideUnavailableAgents || isInstalled {
                let title = isInstalled ? "Open in cmux" : "cmux Not Installed"
                let cmuxItem = NSMenuItem(title: title, action: #selector(openCmuxMenuItem), keyEquivalent: "")
                cmuxItem.target = self
                cmuxItem.isEnabled = state.hasCopyablePath && isInstalled
                menu.addItem(cmuxItem)
                didAddPrimaryLauncher = true
            }
        }

        if FinderPathPreferences.showOpenGhosttyItem {
            let isInstalled = TerminalBridge.isGhosttyInstalled
            if !hideUnavailableAgents || isInstalled {
                let title = isInstalled ? "Open in Ghostty" : "Ghostty Not Installed"
                let ghosttyItem = NSMenuItem(title: title, action: #selector(openGhosttyMenuItem), keyEquivalent: "")
                ghosttyItem.target = self
                ghosttyItem.isEnabled = state.hasCopyablePath && isInstalled
                menu.addItem(ghosttyItem)
                didAddPrimaryLauncher = true
            }
        }

        pendingLauncherSeparator = didAddPrimaryLauncher

        if FinderPathPreferences.showOpenTerminalItem {
            addPendingLauncherSeparator()
            let terminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(openTerminalMenuItem), keyEquivalent: "")
            terminalItem.target = self
            terminalItem.isEnabled = state.hasCopyablePath
            menu.addItem(terminalItem)
        }

        if FinderPathPreferences.showOpenWithCodexItem {
            let availability = AgentLauncher.availability(for: FinderPathPreferences.codexExecutable)
            if !hideUnavailableAgents || availability.isInstalled {
                addPendingLauncherSeparator()
                let title = availability.isInstalled ? "Open with Codex" : "Codex Not Installed"
                let codexItem = NSMenuItem(title: title, action: #selector(openWithCodexMenuItem), keyEquivalent: "")
                codexItem.target = self
                codexItem.isEnabled = state.hasCopyablePath && availability.isInstalled
                menu.addItem(codexItem)
            }
        }

        if FinderPathPreferences.showOpenWithClaudeItem {
            let availability = AgentLauncher.availability(for: FinderPathPreferences.claudeExecutable)
            if !hideUnavailableAgents || availability.isInstalled {
                addPendingLauncherSeparator()
                let title = availability.isInstalled ? "Open with Claude" : "Claude Not Installed"
                let claudeItem = NSMenuItem(title: title, action: #selector(openWithClaudeMenuItem), keyEquivalent: "")
                claudeItem.target = self
                claudeItem.isEnabled = state.hasCopyablePath && availability.isInstalled
                menu.addItem(claudeItem)
            }
        }

        if FinderPathPreferences.showOpenWithHermesItem {
            let availability = AgentLauncher.availability(for: FinderPathPreferences.hermesExecutable)
            if !hideUnavailableAgents || availability.isInstalled {
                addPendingLauncherSeparator()
                let title = availability.isInstalled ? "Open with Hermes" : "Hermes Not Installed"
                let hermesItem = NSMenuItem(title: title, action: #selector(openWithHermesMenuItem), keyEquivalent: "")
                hermesItem.target = self
                hermesItem.isEnabled = state.hasCopyablePath && availability.isInstalled
                menu.addItem(hermesItem)
            }
        }

        if FinderPathPreferences.showConnectToServerItem {
            menu.addItem(.separator())
            let serverItem = NSMenuItem(title: "Connect to Server…", action: #selector(openConnectToServerMenuItem), keyEquivalent: "")
            serverItem.target = self
            menu.addItem(serverItem)
        }

        if FinderPathPreferences.showCheckForUpdatesItem {
            menu.addItem(.separator())

            let updatesItem = NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdatesMenuItem),
                keyEquivalent: ""
            )
            updatesItem.target = self
            menu.addItem(updatesItem)
        }

        if FinderPathPreferences.showQuitItem {
            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit FinderPath", action: #selector(quitMenuItem), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let symbolName = FinderPathPreferences.statusIconSymbolName
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "FinderPath")
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "FinderPath")
        button.image?.isTemplate = true
        button.title = FinderPathPreferences.showStatusTitle ? " \(FinderPathPreferences.statusTitle)" : ""
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openRemoteConnectionWindow() {
        if remoteConnectionWindowController == nil {
            remoteConnectionWindowController = RemoteConnectionWindowController()
        }

        remoteConnectionWindowController?.showWindow(nil)
        remoteConnectionWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsMenuItem() {
        openSettings()
    }

    @objc private func refreshMenuItem() {
        state.refresh()
    }

    @objc private func copyPathMenuItem() {
        state.copyCurrentPath()
    }

    @objc private func copyCDMenuItem() {
        state.copyChangeDirectoryCommand()
    }

    @objc private func openTerminalMenuItem() {
        state.openInTerminal()
    }

    @objc private func openGhosttyMenuItem() {
        state.openInGhostty()
    }

    @objc private func openCmuxMenuItem() {
        state.openInCmux()
    }

    @objc private func openWithCodexMenuItem() {
        state.openWithCodex()
    }

    @objc private func openWithClaudeMenuItem() {
        state.openWithClaude()
    }

    @objc private func openWithHermesMenuItem() {
        state.openWithHermes()
    }

    @objc private func openConnectToServerMenuItem() {
        openRemoteConnectionWindow()
    }

    @objc private func checkForUpdatesMenuItem() {
        state.checkForUpdates(userInitiated: true)
    }

    @objc private func quitMenuItem() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "FinderPath Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @AppStorage(FinderPathPreferences.showPathHeaderKey) private var showPathHeader = true
    @AppStorage(FinderPathPreferences.showRefreshItemKey) private var showRefreshItem = true
    @AppStorage(FinderPathPreferences.showCopyPathItemKey) private var showCopyPathItem = true
    @AppStorage(FinderPathPreferences.showCopyCDItemKey) private var showCopyCDItem = true
    @AppStorage(FinderPathPreferences.showOpenTerminalItemKey) private var showOpenTerminalItem = true
    @AppStorage(FinderPathPreferences.showOpenGhosttyItemKey) private var showOpenGhosttyItem = true
    @AppStorage(FinderPathPreferences.showOpenWithCodexItemKey) private var showOpenWithCodexItem = true
    @AppStorage(FinderPathPreferences.showOpenWithClaudeItemKey) private var showOpenWithClaudeItem = true
    @AppStorage(FinderPathPreferences.showOpenWithHermesItemKey) private var showOpenWithHermesItem = true
    @AppStorage(FinderPathPreferences.showOpenCmuxItemKey) private var showOpenCmuxItem = true
    @AppStorage(FinderPathPreferences.showConnectToServerItemKey) private var showConnectToServerItem = true
    @AppStorage(FinderPathPreferences.showCheckForUpdatesItemKey) private var showCheckForUpdatesItem = true
    @AppStorage(FinderPathPreferences.showQuitItemKey) private var showQuitItem = true
    @AppStorage(FinderPathPreferences.pathDisplayStyleKey) private var pathDisplayStyle = "full"
    @AppStorage(FinderPathPreferences.menuHeaderTitleKey) private var menuHeaderTitle = "Current Finder Path"
    @AppStorage(FinderPathPreferences.menuHeaderWidthKey) private var menuHeaderWidth = 380.0
    @AppStorage(FinderPathPreferences.pathLineBreakKey) private var pathLineBreak = "middle"
    @AppStorage(FinderPathPreferences.pathFontSizeKey) private var pathFontSize = 12.0
    @AppStorage(FinderPathPreferences.statusIconKey) private var statusIcon = "folder"
    @AppStorage(FinderPathPreferences.showStatusTitleKey) private var showStatusTitle = false
    @AppStorage(FinderPathPreferences.statusTitleKey) private var statusTitle = "FP"
    @AppStorage(FinderPathPreferences.cdQuoteStyleKey) private var cdQuoteStyle = "double"
    @AppStorage(FinderPathPreferences.remoteConnectionTerminalKey) private var remoteConnectionTerminal = "ghostty"
    @AppStorage(FinderPathPreferences.codexExecutableKey) private var codexExecutable = "codex"
    @AppStorage(FinderPathPreferences.claudeExecutableKey) private var claudeExecutable = "claude"
    @AppStorage(FinderPathPreferences.hermesExecutableKey) private var hermesExecutable = "hermes"
    @AppStorage(FinderPathPreferences.hideUnavailableAgentItemsKey) private var hideUnavailableAgentItems = true
    @AppStorage(FinderPathPreferences.updateManifestURLKey) private var updateManifestURL = FinderPathPreferences.defaultUpdateManifestURL
    @State private var codexAvailability = AgentAvailability.unknown(executable: "codex")
    @State private var claudeAvailability = AgentAvailability.unknown(executable: "claude")
    @State private var hermesAvailability = AgentAvailability.unknown(executable: "hermes")
    @State private var isCheckingForUpdates = false

    var body: some View {
        Form {
            Section("Menu Items") {
                Toggle("Show current path header", isOn: $showPathHeader)
                Toggle("Show Refresh", isOn: $showRefreshItem)
                Toggle("Show Copy Path", isOn: $showCopyPathItem)
                Toggle("Show Copy cd Command", isOn: $showCopyCDItem)
                Toggle("Show Open in cmux", isOn: $showOpenCmuxItem)
                Toggle("Show Open in Ghostty", isOn: $showOpenGhosttyItem)
                Toggle("Show Open in Terminal", isOn: $showOpenTerminalItem)
                Toggle("Show Open with Codex", isOn: $showOpenWithCodexItem)
                Toggle("Show Open with Claude", isOn: $showOpenWithClaudeItem)
                Toggle("Show Open with Hermes", isOn: $showOpenWithHermesItem)
                Toggle("Show Connect to Server", isOn: $showConnectToServerItem)
                Toggle("Show Check for Updates", isOn: $showCheckForUpdatesItem)
                Toggle("Show Quit", isOn: $showQuitItem)
            }

            Section("Path Header") {
                TextField("Header title", text: $menuHeaderTitle)

                Picker("Path display", selection: $pathDisplayStyle) {
                    Text("Full").tag("full")
                    Text("Home as ~").tag("home")
                    Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)

                Picker("Long path truncation", selection: $pathLineBreak) {
                    Text("Start").tag("head")
                    Text("Middle").tag("middle")
                    Text("End").tag("tail")
                }
                .pickerStyle(.segmented)

                LabeledContent("Header width") {
                    HStack {
                        Slider(value: $menuHeaderWidth, in: 300...560, step: 20)
                        Text("\(Int(menuHeaderWidth)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }

                LabeledContent("Path font size") {
                    HStack {
                        Slider(value: $pathFontSize, in: 10...15, step: 1)
                        Text("\(Int(pathFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Menu Bar Icon") {
                Picker("Icon", selection: $statusIcon) {
                    Label("Folder", systemImage: "folder").tag("folder")
                    Label("Folder Badge", systemImage: "folder.badge.gearshape").tag("folder.badge.gearshape")
                    Label("Terminal", systemImage: "terminal").tag("terminal")
                    Label("Path", systemImage: "point.topleft.down.curvedto.point.bottomright.up").tag("point.topleft.down.curvedto.point.bottomright.up")
                }
                .pickerStyle(.menu)

                Toggle("Show short title", isOn: $showStatusTitle)

                if showStatusTitle {
                    TextField("Short title", text: $statusTitle)
                }
            }

            Section("Terminal") {
                Picker("cd quoting", selection: $cdQuoteStyle) {
                    Text("Double quotes").tag("double")
                    Text("Single quotes").tag("single")
                }
                .pickerStyle(.segmented)
            }

            Section("Remote Connections") {
                Picker("Run SSH connections in", selection: $remoteConnectionTerminal) {
                    Text("Ghostty").tag("ghostty")
                    Text("macOS Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)

                Text("Add servers and connect from the \"Connect to Server\" window (menu bar → Connect to Server…). Your Tailscale devices appear there automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Agent Launchers") {
                TextField("Codex command or path", text: $codexExecutable)
                TextField("Claude command or path", text: $claudeExecutable)
                TextField("Hermes command or path", text: $hermesExecutable)
                Toggle("Hide unavailable agent actions", isOn: $hideUnavailableAgentItems)

                AgentStatusRow(name: "Codex", availability: codexAvailability)
                AgentStatusRow(name: "Claude", availability: claudeAvailability)
                AgentStatusRow(name: "Hermes", availability: hermesAvailability)

                HStack {
                    Button("Check Again", action: refreshAgentAvailability)
                    Spacer()
                }

                Text("Codex, Claude, and Hermes are optional. If a CLI is not installed, FinderPath can hide that menu action. Use a full executable path if your command is installed outside the normal shell PATH.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Installed version", value: AppVersion.current)

                TextField("Update manifest URL", text: $updateManifestURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(isCheckingForUpdates ? "Checking..." : "Check for Updates Now", action: checkForUpdatesFromSettings)
                        .disabled(isCheckingForUpdates)
                    Spacer()
                }

                Text("FinderPath checks GitHub Releases for the latest tagged version and compares it to the one installed. Defaults to bhino50/finder-path; point this at any GitHub Releases API URL or a plain `{ version, downloadURL, notes }` JSON manifest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                LabeledContent("Click", value: "Path menu")
                LabeledContent("Right-click", value: "Path menu")
            }

            Section {
                Button("Reset to Defaults", action: resetDefaults)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 700)
        .onAppear(perform: refreshAgentAvailability)
        .onChange(of: codexExecutable) { _ in
            refreshAgentAvailability()
        }
        .onChange(of: claudeExecutable) { _ in
            refreshAgentAvailability()
        }
        .onChange(of: hermesExecutable) { _ in
            refreshAgentAvailability()
        }
    }

    private func resetDefaults() {
        showPathHeader = true
        showRefreshItem = true
        showCopyPathItem = true
        showCopyCDItem = true
        showOpenTerminalItem = true
        showOpenGhosttyItem = true
        showOpenWithCodexItem = true
        showOpenWithClaudeItem = true
        showOpenWithHermesItem = true
        showOpenCmuxItem = true
        showConnectToServerItem = true
        showCheckForUpdatesItem = true
        showQuitItem = true
        pathDisplayStyle = "full"
        menuHeaderTitle = "Current Finder Path"
        menuHeaderWidth = 380
        pathLineBreak = "middle"
        pathFontSize = 12
        statusIcon = "folder"
        showStatusTitle = false
        statusTitle = "FP"
        cdQuoteStyle = "double"
        remoteConnectionTerminal = "ghostty"
        codexExecutable = "codex"
        claudeExecutable = "claude"
        hermesExecutable = "hermes"
        hideUnavailableAgentItems = true
        updateManifestURL = FinderPathPreferences.defaultUpdateManifestURL
        refreshAgentAvailability()
    }

    private func refreshAgentAvailability() {
        codexAvailability = AgentLauncher.availability(for: codexExecutable, defaultExecutable: "codex")
        claudeAvailability = AgentLauncher.availability(for: claudeExecutable, defaultExecutable: "claude")
        hermesAvailability = AgentLauncher.availability(for: hermesExecutable, defaultExecutable: "hermes")
    }

    private func checkForUpdatesFromSettings() {
        isCheckingForUpdates = true
        let currentVersion = AppVersion.current
        UpdateChecker.check(manifestURL: FinderPathPreferences.updateManifestURL) { result in
            Task { @MainActor in
                isCheckingForUpdates = false
                UpdatePrompt.present(
                    result: result,
                    currentVersion: currentVersion,
                    userInitiated: true
                )
            }
        }
    }
}

struct AgentStatusRow: View {
    let name: String
    let availability: AgentAvailability

    var body: some View {
        LabeledContent("\(name) status") {
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    availability.isInstalled ? "Installed" : "Not Found",
                    systemImage: availability.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(availability.isInstalled ? Color.green : Color.secondary)

                Text(availability.resolvedPath ?? availability.executable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
final class RemoteConnectionWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Connect to Server"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: RemoteConnectionView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct RemoteConnectionView: View {
    @AppStorage(FinderPathPreferences.remoteServersKey) private var remoteServersText = ""
    @AppStorage(FinderPathPreferences.remoteConnectionTerminalKey) private var remoteConnectionTerminal = "ghostty"

    @State private var selection: String?
    @State private var selectedTarget = ""
    @State private var user = ""
    @State private var tailscale = TailscaleStatus.unavailable
    @State private var showAllDevices = false
    @State private var isLoadingTailscale = false
    @State private var isTogglingVPN = false
    @State private var isAddingServer = false
    @State private var newServerName = ""
    @State private var newServerTarget = ""
    @State private var errorMessage: String?

    private var servers: [RemoteServer] {
        RemoteServers.parse(remoteServersText)
    }

    private var visibleDevices: [TailscaleDevice] {
        tailscale.devices.filter { device in
            guard !device.address.isEmpty else { return false }
            return showAllDevices || device.isLinux
        }
    }

    private var selectedServerIndex: Int? {
        guard let selection, selection.hasPrefix("srv:") else { return nil }
        return Int(selection.dropFirst(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tailscaleHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    deviceSection
                    serverSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 460, height: 580)
        .onAppear { Task { await refreshTailscale() } }
        .alert("Connection problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isAddingServer) { addServerSheet }
    }

    private var tailscaleHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(tailscale.isRunning ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tailscale").font(.headline)
                Text(tailscaleStatusText).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if tailscale.backend == .unavailable {
                Text("Not installed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(tailscale.isRunning ? "Disconnect" : "Connect") { toggleVPN() }
                    .disabled(isTogglingVPN || tailscale.backend == .needsLogin)
            }
        }
    }

    private var tailscaleStatusText: String {
        switch tailscale.backend {
        case .running:
            return tailscale.selfAddress.map { "Connected · \($0)" } ?? "Connected"
        case .stopped:
            return "Disconnected"
        case .needsLogin:
            return "Needs login — open the Tailscale app"
        case .unavailable:
            return "Tailscale CLI not found"
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tailscale Devices").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("Show all", isOn: $showAllDevices)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    Task { await refreshTailscale() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingTailscale)
            }

            if visibleDevices.isEmpty {
                Text(deviceEmptyText).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(visibleDevices) { device in
                    connectionRow(
                        id: "ts:\(device.id)",
                        title: device.name,
                        subtitle: "\(device.address) · \(device.os)",
                        online: device.online,
                        target: device.name.isEmpty ? device.address : device.name
                    )
                }
            }
        }
    }

    private var deviceEmptyText: String {
        if tailscale.backend == .unavailable { return "Tailscale is not installed." }
        if isLoadingTailscale { return "Loading devices…" }
        return showAllDevices ? "No devices online." : "No Linux devices online. Enable \"Show all\" to see every device."
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("My Servers").font(.subheadline.weight(.semibold))
                Spacer()
                Button { beginAddServer() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                Button { removeSelectedServer() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selectedServerIndex == nil)
            }

            if servers.isEmpty {
                Text("No servers yet. Click + to add one (e.g. My Server = myserver).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                    connectionRow(
                        id: "srv:\(index)",
                        title: server.name,
                        subtitle: server.target,
                        online: nil,
                        target: server.target
                    )
                }
            }
        }
    }

    private func connectionRow(id: String, title: String, subtitle: String, online: Bool?, target: String) -> some View {
        HStack(spacing: 8) {
            if let online {
                Circle()
                    .fill(online ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selection == id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            select(id: id, target: target)
            connect()
        }
        .onTapGesture {
            select(id: id, target: target)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("User").frame(width: 48, alignment: .leading)
                TextField("optional (e.g. admin)", text: $user)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Open in").frame(width: 48, alignment: .leading)
                Picker("", selection: $remoteConnectionTerminal) {
                    Text("Ghostty").tag("ghostty")
                    Text("macOS Terminal").tag("terminal")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Server").font(.headline)
            TextField("Name (e.g. Linux Tower)", text: $newServerName)
                .textFieldStyle(.roundedBorder)
            TextField("ssh target (e.g. myserver or user@host)", text: $newServerTarget)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isAddingServer = false }
                Button("Add") { commitAddServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newServerTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func select(id: String, target: String) {
        selection = id
        selectedTarget = target
    }

    private func beginAddServer() {
        newServerName = ""
        newServerTarget = ""
        isAddingServer = true
    }

    private func commitAddServer() {
        let name = newServerName.trimmingCharacters(in: .whitespaces)
        let target = newServerTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }

        var current = servers
        current.append(RemoteServer(name: name.isEmpty ? target : name, target: target))
        remoteServersText = RemoteServers.serialize(current)
        isAddingServer = false
    }

    private func removeSelectedServer() {
        guard let index = selectedServerIndex else { return }

        var current = servers
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        remoteServersText = RemoteServers.serialize(current)
        selection = nil
    }

    private func connect() {
        guard !selectedTarget.isEmpty else { return }

        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let host = (!trimmedUser.isEmpty && !selectedTarget.contains("@"))
            ? "\(trimmedUser)@\(selectedTarget)"
            : selectedTarget

        let terminal = TerminalBridge.RemoteTerminal(rawValue: remoteConnectionTerminal) ?? .ghostty
        TerminalBridge.openSSH(host: host, using: terminal) { error in
            guard let error else { return }
            Task { @MainActor in errorMessage = error }
        }
    }

    private func toggleVPN() {
        isTogglingVPN = true
        let goingUp = !tailscale.isRunning
        Task {
            let error = await Task.detached { goingUp ? TailscaleBridge.up() : TailscaleBridge.down() }.value
            isTogglingVPN = false
            if let error { errorMessage = error }
            await refreshTailscale()
        }
    }

    private func refreshTailscale() async {
        isLoadingTailscale = true
        tailscale = await Task.detached { TailscaleBridge.status() }.value
        isLoadingTailscale = false
    }
}

enum FinderPathPreferences {
    static let showPathHeaderKey = "showPathHeader"
    static let showRefreshItemKey = "showRefreshItem"
    static let showCopyPathItemKey = "showCopyPathItem"
    static let showCopyCDItemKey = "showCopyCDItem"
    static let showOpenTerminalItemKey = "showOpenTerminalItem"
    static let showOpenGhosttyItemKey = "showOpenGhosttyItem"
    static let showOpenWithCodexItemKey = "showOpenWithCodexItem"
    static let showOpenWithClaudeItemKey = "showOpenWithClaudeItem"
    static let showOpenWithHermesItemKey = "showOpenWithHermesItem"
    static let showOpenCmuxItemKey = "showOpenCmuxItem"
    static let showConnectToServerItemKey = "showConnectToServerItem"
    static let remoteConnectionTerminalKey = "remoteConnectionTerminal"
    static let remoteServersKey = "remoteServers"
    static let showCheckForUpdatesItemKey = "showCheckForUpdatesItem"
    static let showQuitItemKey = "showQuitItem"
    static let pathDisplayStyleKey = "pathDisplayStyle"
    static let menuHeaderTitleKey = "menuHeaderTitle"
    static let menuHeaderWidthKey = "menuHeaderWidth"
    static let pathLineBreakKey = "pathLineBreak"
    static let pathFontSizeKey = "pathFontSize"
    static let statusIconKey = "statusIcon"
    static let showStatusTitleKey = "showStatusTitle"
    static let statusTitleKey = "statusTitle"
    static let cdQuoteStyleKey = "cdQuoteStyle"
    static let codexExecutableKey = "codexExecutable"
    static let claudeExecutableKey = "claudeExecutable"
    static let hermesExecutableKey = "hermesExecutable"
    static let hideUnavailableAgentItemsKey = "hideUnavailableAgentItems"
    static let updateManifestURLKey = "updateManifestURL"
    static let defaultUpdateManifestURL = "https://api.github.com/repos/bhino50/finder-path/releases/latest"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showPathHeaderKey: true,
            showRefreshItemKey: true,
            showCopyPathItemKey: true,
            showCopyCDItemKey: true,
            showOpenTerminalItemKey: true,
            showOpenGhosttyItemKey: true,
            showOpenWithCodexItemKey: true,
            showOpenWithClaudeItemKey: true,
            showOpenWithHermesItemKey: true,
            showOpenCmuxItemKey: true,
            showConnectToServerItemKey: true,
            remoteConnectionTerminalKey: "ghostty",
            remoteServersKey: "",
            showCheckForUpdatesItemKey: true,
            showQuitItemKey: true,
            pathDisplayStyleKey: "full",
            menuHeaderTitleKey: "Current Finder Path",
            menuHeaderWidthKey: 380.0,
            pathLineBreakKey: "middle",
            pathFontSizeKey: 12.0,
            statusIconKey: "folder",
            showStatusTitleKey: false,
            statusTitleKey: "FP",
            cdQuoteStyleKey: "double",
            codexExecutableKey: "codex",
            claudeExecutableKey: "claude",
            hermesExecutableKey: "hermes",
            hideUnavailableAgentItemsKey: true,
            updateManifestURLKey: defaultUpdateManifestURL
        ])
    }

    static var showPathHeader: Bool {
        bool(for: showPathHeaderKey, defaultValue: true)
    }

    static var showRefreshItem: Bool {
        bool(for: showRefreshItemKey, defaultValue: true)
    }

    static var showCopyPathItem: Bool {
        bool(for: showCopyPathItemKey, defaultValue: true)
    }

    static var showCopyCDItem: Bool {
        bool(for: showCopyCDItemKey, defaultValue: true)
    }

    static var showOpenTerminalItem: Bool {
        bool(for: showOpenTerminalItemKey, defaultValue: true)
    }

    static var showOpenGhosttyItem: Bool {
        bool(for: showOpenGhosttyItemKey, defaultValue: true)
    }

    static var showOpenWithCodexItem: Bool {
        bool(for: showOpenWithCodexItemKey, defaultValue: true)
    }

    static var showOpenWithClaudeItem: Bool {
        bool(for: showOpenWithClaudeItemKey, defaultValue: true)
    }

    static var showOpenWithHermesItem: Bool {
        bool(for: showOpenWithHermesItemKey, defaultValue: true)
    }

    static var showOpenCmuxItem: Bool {
        bool(for: showOpenCmuxItemKey, defaultValue: true)
    }

    static var showConnectToServerItem: Bool {
        bool(for: showConnectToServerItemKey, defaultValue: true)
    }

    static var remoteConnectionTerminal: String {
        string(for: remoteConnectionTerminalKey, defaultValue: "ghostty") == "terminal" ? "terminal" : "ghostty"
    }

    static var remoteServers: String {
        string(for: remoteServersKey, defaultValue: "")
    }

    static var showCheckForUpdatesItem: Bool {
        bool(for: showCheckForUpdatesItemKey, defaultValue: true)
    }

    static var showQuitItem: Bool {
        bool(for: showQuitItemKey, defaultValue: true)
    }

    static var pathDisplayStyle: String {
        string(for: pathDisplayStyleKey, defaultValue: "full")
    }

    static var menuHeaderTitle: String {
        let title = string(for: menuHeaderTitleKey, defaultValue: "Current Finder Path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Current Finder Path" : title
    }

    static var menuHeaderWidth: CGFloat {
        CGFloat(clamp(double(for: menuHeaderWidthKey, defaultValue: 380), min: 300, max: 560))
    }

    static var pathLineBreakMode: NSLineBreakMode {
        switch string(for: pathLineBreakKey, defaultValue: "middle") {
        case "head":
            return .byTruncatingHead
        case "tail":
            return .byTruncatingTail
        default:
            return .byTruncatingMiddle
        }
    }

    static var pathFontSize: CGFloat {
        CGFloat(clamp(double(for: pathFontSizeKey, defaultValue: 12), min: 10, max: 15))
    }

    static var statusIconSymbolName: String {
        let symbol = string(for: statusIconKey, defaultValue: "folder")
        switch symbol {
        case "folder", "folder.badge.gearshape", "terminal", "point.topleft.down.curvedto.point.bottomright.up":
            return symbol
        default:
            return "folder"
        }
    }

    static var showStatusTitle: Bool {
        bool(for: showStatusTitleKey, defaultValue: false)
    }

    static var statusTitle: String {
        let title = string(for: statusTitleKey, defaultValue: "FP")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((title.isEmpty ? "FP" : title).prefix(8))
    }

    static var cdQuoteStyle: String {
        string(for: cdQuoteStyleKey, defaultValue: "double")
    }

    static var codexExecutable: String {
        sanitizedExecutable(for: codexExecutableKey, defaultValue: "codex")
    }

    static var claudeExecutable: String {
        sanitizedExecutable(for: claudeExecutableKey, defaultValue: "claude")
    }

    static var hermesExecutable: String {
        sanitizedExecutable(for: hermesExecutableKey, defaultValue: "hermes")
    }

    static var hideUnavailableAgentItems: Bool {
        bool(for: hideUnavailableAgentItemsKey, defaultValue: true)
    }

    static var updateManifestURL: String {
        let value = string(for: updateManifestURLKey, defaultValue: defaultUpdateManifestURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultUpdateManifestURL : value
    }

    static func displayPath(for path: String) -> String {
        guard !path.hasPrefix("Finder AppleScript error:") else { return path }

        switch pathDisplayStyle {
        case "home":
            return abbreviatingHomeDirectory(path)
        case "compact":
            return compactPath(path)
        default:
            return path
        }
    }

    private static func abbreviatingHomeDirectory(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }

        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }

        return path
    }

    private static func compactPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents.filter { $0 != "/" }

        if components.count >= 2 {
            return ".../\(components[components.count - 2])/\(components[components.count - 1])"
        }

        return abbreviatingHomeDirectory(path)
    }

    private static func bool(for key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }

        return UserDefaults.standard.bool(forKey: key)
    }

    private static func string(for key: String, defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    private static func sanitizedExecutable(for key: String, defaultValue: String) -> String {
        let value = string(for: key, defaultValue: defaultValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultValue : value
    }

    private static func double(for key: String, defaultValue: Double) -> Double {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }

        return UserDefaults.standard.double(forKey: key)
    }

    private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}

final class PathMenuHeaderView: NSView {
    init(path: String, isError: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: FinderPathPreferences.menuHeaderWidth, height: 54))

        let titleLabel = NSTextField(labelWithString: FinderPathPreferences.menuHeaderTitle)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: path.isEmpty ? "Fetching Finder path..." : path)
        pathLabel.font = .monospacedSystemFont(ofSize: FinderPathPreferences.pathFontSize, weight: .regular)
        pathLabel.textColor = isError ? .systemRed : .labelColor
        pathLabel.lineBreakMode = FinderPathPreferences.pathLineBreakMode
        pathLabel.maximumNumberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

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

struct RemoteServer: Equatable {
    let name: String
    let target: String
}

enum RemoteServers {
    // Parses the user's curated server list (stored as plain text in preferences).
    // One server per line, in the form `Name = ssh-target`, for example:
    //   My Server = myserver
    // The target can be a ~/.ssh/config alias or a `user@host` string. A line with
    // no `=` is used as both the display name and the target. Blank lines and lines
    // starting with `#` are ignored.
    static func parse(_ text: String) -> [RemoteServer] {
        var servers: [RemoteServer] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                servers.append(RemoteServer(name: line, target: line))
                continue
            }

            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let target = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }

            servers.append(RemoteServer(name: name.isEmpty ? target : name, target: target))
        }

        return servers
    }

    static func serialize(_ servers: [RemoteServer]) -> String {
        servers.map { "\($0.name) = \($0.target)" }.joined(separator: "\n")
    }
}

struct TailscaleDevice: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    let os: String
    let online: Bool

    var id: String { address.isEmpty ? name : address }
    var isLinux: Bool { os.lowercased() == "linux" }
}

struct TailscaleStatus: Sendable {
    enum Backend: Sendable { case running, stopped, needsLogin, unavailable }

    let backend: Backend
    let selfAddress: String?
    let devices: [TailscaleDevice]

    static let unavailable = TailscaleStatus(backend: .unavailable, selfAddress: nil, devices: [])

    var isRunning: Bool { backend == .running }
}

enum TailscaleBridge {
    static let appExecutablePath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    static func executablePath() -> String? {
        if let resolved = AgentLauncher.availability(for: "tailscale", defaultExecutable: "tailscale").resolvedPath {
            return resolved
        }

        for candidate in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", appExecutablePath] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static var isInstalled: Bool { executablePath() != nil }

    static func status() -> TailscaleStatus {
        guard let path = executablePath(),
              let data = run(path, arguments: ["status", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }

        let backend: TailscaleStatus.Backend
        switch json["BackendState"] as? String {
        case "Running": backend = .running
        case "NeedsLogin", "NoState": backend = .needsLogin
        default: backend = .stopped
        }

        let selfNode = json["Self"] as? [String: Any]
        let selfAddress = (selfNode?["TailscaleIPs"] as? [String])?.first

        var devices: [TailscaleDevice] = []
        if let peers = json["Peer"] as? [String: [String: Any]] {
            for peer in peers.values {
                // Prefer the MagicDNS short name (first label of DNSName): it resolves over
                // the tailnet and matches ~/.ssh/config aliases, so `ssh <name>` uses the
                // right user/key. The raw HostName can be uppercased or differ from the
                // alias, so it often resolves to neither.
                let shortName = (peer["DNSName"] as? String)
                    .flatMap { $0.split(separator: ".").first }
                    .map(String.init)
                let name = shortName ?? (peer["HostName"] as? String) ?? "unknown"
                let address = (peer["TailscaleIPs"] as? [String])?.first ?? ""
                let os = (peer["OS"] as? String) ?? ""
                let online = (peer["Online"] as? Bool) ?? false
                devices.append(TailscaleDevice(name: name, address: address, os: os, online: online))
            }
        }

        devices.sort { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online && !rhs.online }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return TailscaleStatus(backend: backend, selfAddress: selfAddress, devices: devices)
    }

    @discardableResult
    static func up() -> String? { runVoid(arguments: ["up"]) }

    @discardableResult
    static func down() -> String? { runVoid(arguments: ["down"]) }

    // Runs a tailscale subcommand for its side effect. Returns an error message on failure, nil on success.
    private static func runVoid(arguments: [String]) -> String? {
        guard let path = executablePath() else {
            return "Tailscale CLI was not found."
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let errorPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "Could not run tailscale: \(error.localizedDescription)"
        }

        if task.terminationStatus == 0 { return nil }

        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : "tailscale \(arguments.joined(separator: " ")) failed."
    }

    private static func run(_ path: String, arguments: [String]) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}

enum ShellCommand {
    static func argument(_ value: String, quoteStyle: String = "single") -> String {
        switch quoteStyle {
        case "double":
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")

            return "\"\(escaped)\""
        default:
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }
}

struct AgentAvailability: Equatable {
    let executable: String
    let resolvedPath: String?

    var isInstalled: Bool {
        resolvedPath != nil
    }

    static func unknown(executable: String) -> AgentAvailability {
        AgentAvailability(executable: executable, resolvedPath: nil)
    }
}

enum AgentLauncher {
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

enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "unknown"
        }
    }

    static var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

struct UpdateManifest: Equatable {
    let latestVersion: String
    let downloadURL: URL?
    let releaseNotes: String?
}

enum UpdateCheckResult {
    case upToDate(latest: String)
    case updateAvailable(manifest: UpdateManifest)
    case failed(message: String)
}

enum UpdateChecker {
    static func check(manifestURL: String, completion: @escaping (UpdateCheckResult) -> Void) {
        let trimmed = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion(.failed(message: "The update manifest URL is not a valid web URL."))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if url.host?.contains("api.github.com") == true {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("FinderPath/\(AppVersion.shortVersionString)", forHTTPHeaderField: "User-Agent")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failed(message: "Could not reach the update server: \(error.localizedDescription)"))
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failed(message: "Update server returned HTTP \(http.statusCode)."))
                return
            }

            guard let data else {
                completion(.failed(message: "Update server returned no data."))
                return
            }

            guard let manifest = parseManifest(data) else {
                completion(.failed(message: "Could not parse the update manifest. Expected JSON with a version field."))
                return
            }

            let current = AppVersion.shortVersionString
            if compare(manifest.latestVersion, isNewerThan: current) {
                completion(.updateAvailable(manifest: manifest))
            } else {
                completion(.upToDate(latest: manifest.latestVersion))
            }
        }.resume()
    }

    private static func parseManifest(_ data: Data) -> UpdateManifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let tag = json["tag_name"] as? String {
            return parseGitHubRelease(json: json, tag: tag)
        }

        let versionString = (json["version"] as? String)
            ?? (json["latest"] as? String)
            ?? (json["latestVersion"] as? String)

        guard let version = versionString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil
        }

        let downloadString = (json["downloadURL"] as? String)
            ?? (json["url"] as? String)
            ?? (json["download_url"] as? String)
        let downloadURL = downloadString.flatMap { URL(string: $0) }

        let notes = (json["notes"] as? String)
            ?? (json["releaseNotes"] as? String)
            ?? (json["release_notes"] as? String)

        return UpdateManifest(
            latestVersion: version,
            downloadURL: downloadURL,
            releaseNotes: notes
        )
    }

    private static func parseGitHubRelease(json: [String: Any], tag: String) -> UpdateManifest? {
        let version = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])

        guard !version.isEmpty else { return nil }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let dmgURL = assets
            .first { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        let zipURL = assets
            .first { (($0["name"] as? String) ?? "").hasSuffix(".zip") }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))

        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return UpdateManifest(
            latestVersion: version,
            downloadURL: dmgURL ?? zipURL ?? pageURL,
            releaseNotes: notes?.isEmpty == false ? notes : nil
        )
    }

    static func compare(_ candidate: String, isNewerThan installed: String) -> Bool {
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(installed)
        let length = max(lhs.count, rhs.count)

        for index in 0..<length {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }

        return false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: .caseInsensitive)

        return cleaned
            .split(separator: ".")
            .map { component -> Int in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

@MainActor
enum UpdatePrompt {
    static func present(result: UpdateCheckResult, currentVersion: String, userInitiated: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch result {
        case .upToDate(let latest):
            alert.messageText = "FinderPath is up to date."
            alert.informativeText = "You are running version \(currentVersion). Latest available is \(latest)."
            alert.addButton(withTitle: "OK")

        case .updateAvailable(let manifest):
            alert.messageText = "A new version of FinderPath is available."
            var detail = "Installed: \(currentVersion)\nLatest: \(manifest.latestVersion)"
            if let notes = manifest.releaseNotes, !notes.isEmpty {
                detail += "\n\n\(notes)"
            }
            alert.informativeText = detail
            alert.addButton(withTitle: manifest.downloadURL == nil ? "OK" : "Download")
            alert.addButton(withTitle: "Later")

        case .failed(let message):
            guard userInitiated else { return }
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates."
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if case .updateAvailable(let manifest) = result,
           response == .alertFirstButtonReturn,
           let url = manifest.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }
}
