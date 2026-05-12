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

    @objc private func openWithCodexMenuItem() {
        state.openWithCodex()
    }

    @objc private func openWithClaudeMenuItem() {
        state.openWithClaude()
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
    @AppStorage(FinderPathPreferences.showOpenWithCodexItemKey) private var showOpenWithCodexItem = true
    @AppStorage(FinderPathPreferences.showOpenWithClaudeItemKey) private var showOpenWithClaudeItem = true
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
    @AppStorage(FinderPathPreferences.hideUnavailableAgentItemsKey) private var hideUnavailableAgentItems = true
    @State private var codexAvailability = AgentAvailability.unknown(executable: "codex")
    @State private var claudeAvailability = AgentAvailability.unknown(executable: "claude")

    var body: some View {
        Form {
            Section("Menu Items") {
                Toggle("Show current path header", isOn: $showPathHeader)
                Toggle("Show Refresh", isOn: $showRefreshItem)
                Toggle("Show Copy Path", isOn: $showCopyPathItem)
                Toggle("Show Copy cd Command", isOn: $showCopyCDItem)
                Toggle("Show Open in Terminal", isOn: $showOpenTerminalItem)
                Toggle("Show Open with Codex", isOn: $showOpenWithCodexItem)
                Toggle("Show Open with Claude", isOn: $showOpenWithClaudeItem)
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
                Toggle("Hide unavailable agent actions", isOn: $hideUnavailableAgentItems)

                AgentStatusRow(name: "Codex", availability: codexAvailability)
                AgentStatusRow(name: "Claude", availability: claudeAvailability)

                HStack {
                    Button("Check Again", action: refreshAgentAvailability)
                    Spacer()
                }

                Text("Codex and Claude are optional. If a CLI is not installed, FinderPath can hide that menu action. Use a full executable path if your command is installed outside the normal shell PATH.")
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
    }

    private func resetDefaults() {
        showPathHeader = true
        showRefreshItem = true
        showCopyPathItem = true
        showCopyCDItem = true
        showOpenTerminalItem = true
        showOpenWithCodexItem = true
        showOpenWithClaudeItem = true
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
        hideUnavailableAgentItems = true
        refreshAgentAvailability()
    }

    private func refreshAgentAvailability() {
        codexAvailability = AgentLauncher.availability(for: codexExecutable, defaultExecutable: "codex")
        claudeAvailability = AgentLauncher.availability(for: claudeExecutable, defaultExecutable: "claude")
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
    static let showOpenWithCodexItemKey = "showOpenWithCodexItem"
    static let showOpenWithClaudeItemKey = "showOpenWithClaudeItem"
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
    static let hideUnavailableAgentItemsKey = "hideUnavailableAgentItems"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showPathHeaderKey: true,
            showRefreshItemKey: true,
            showCopyPathItemKey: true,
            showCopyCDItemKey: true,
            showOpenTerminalItemKey: true,
            showOpenWithCodexItemKey: true,
            showOpenWithClaudeItemKey: true,
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
            hideUnavailableAgentItemsKey: true
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

    static var showOpenWithCodexItem: Bool {
        bool(for: showOpenWithCodexItemKey, defaultValue: true)
    }

    static var showOpenWithClaudeItem: Bool {
        bool(for: showOpenWithClaudeItemKey, defaultValue: true)
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

    static var hideUnavailableAgentItems: Bool {
        bool(for: hideUnavailableAgentItemsKey, defaultValue: true)
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
