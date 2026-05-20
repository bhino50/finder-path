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

    func applicationDidFinishLaunching(_ notification: Notification) {
        FinderPathPreferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
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

        if FinderPathPreferences.showOpenTerminalItem {
            let terminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(openTerminalMenuItem), keyEquivalent: "")
            terminalItem.target = self
            terminalItem.isEnabled = state.hasCopyablePath
            menu.addItem(terminalItem)
        }

        let hideUnavailableAgents = FinderPathPreferences.hideUnavailableAgentItems

        if FinderPathPreferences.showOpenGhosttyItem {
            let isInstalled = TerminalBridge.isGhosttyInstalled
            if !hideUnavailableAgents || isInstalled {
                let title = isInstalled ? "Open in Ghostty" : "Ghostty Not Installed"
                let ghosttyItem = NSMenuItem(title: title, action: #selector(openGhosttyMenuItem), keyEquivalent: "")
                ghosttyItem.target = self
                ghosttyItem.isEnabled = state.hasCopyablePath && isInstalled
                menu.addItem(ghosttyItem)
            }
        }

        if FinderPathPreferences.showOpenWithCodexItem {
            let availability = AgentLauncher.availability(for: FinderPathPreferences.codexExecutable)
            if !hideUnavailableAgents || availability.isInstalled {
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
                let title = availability.isInstalled ? "Open with Hermes" : "Hermes Not Installed"
                let hermesItem = NSMenuItem(title: title, action: #selector(openWithHermesMenuItem), keyEquivalent: "")
                hermesItem.target = self
                hermesItem.isEnabled = state.hasCopyablePath && availability.isInstalled
                menu.addItem(hermesItem)
            }
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

    @objc private func openWithCodexMenuItem() {
        state.openWithCodex()
    }

    @objc private func openWithClaudeMenuItem() {
        state.openWithClaude()
    }

    @objc private func openWithHermesMenuItem() {
        state.openWithHermes()
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
                Toggle("Show Open in Terminal", isOn: $showOpenTerminalItem)
                Toggle("Show Open in Ghostty", isOn: $showOpenGhosttyItem)
                Toggle("Show Open with Codex", isOn: $showOpenWithCodexItem)
                Toggle("Show Open with Claude", isOn: $showOpenWithClaudeItem)
                Toggle("Show Open with Hermes", isOn: $showOpenWithHermesItem)
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
        // NSAppleScript asks Finder for the target folder of its front window and
        // converts that Finder alias into a POSIX path. The fallback keeps the
        // app useful when Finder is open but has no windows.
        let source = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (path to desktop folder as alias)
            end if
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

    static var isGhosttyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier) != nil
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

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // Ghostty accepts the working directory via an opened folder URL,
        // matching how we hand a path off to Terminal.app.
        NSWorkspace.shared.open([directoryURL], withApplicationAt: ghosttyURL, configuration: configuration) { _, error in
            if let error {
                completion("Could not open Ghostty: \(error.localizedDescription)")
            } else {
                completion(nil)
            }
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
