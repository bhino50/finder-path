import AppKit

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
    static let completedWelcomeKey = "completedWelcome"
    static let updateManifestURLKey = "updateManifestURL"
    static let showTerminalsSectionKey = "showTerminalsSection"
    static let terminalFontSizeKey = "terminalFontSize"
    static let terminalScrollbackLimitKey = "terminalScrollbackLimit"
    static let terminalShellOverrideKey = "terminalShellOverride"
    static let rightClickOpensTerminalsKey = "rightClickOpensTerminals"
    static let defaultUpdateManifestURL = "https://api.github.com/repos/bhino50/finder-path/releases/latest"

    static var completedWelcome: Bool {
        bool(for: completedWelcomeKey, defaultValue: false)
    }

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
            updateManifestURLKey: defaultUpdateManifestURL,
            showTerminalsSectionKey: true,
            terminalFontSizeKey: 12.0,
            terminalScrollbackLimitKey: 2000,
            terminalShellOverrideKey: "",
            rightClickOpensTerminalsKey: true,
            completedWelcomeKey: false
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

    static var showTerminalsSection: Bool {
        bool(for: showTerminalsSectionKey, defaultValue: true)
    }

    static var terminalFontSize: Double {
        clamp(double(for: terminalFontSizeKey, defaultValue: 12), min: 9, max: 24)
    }

    static var terminalScrollbackLimit: Int {
        Int(clamp(Double(integer(for: terminalScrollbackLimitKey, defaultValue: 2000)), min: 100, max: 20000))
    }

    /// Empty string means the user's login shell; the session layer resolves it.
    static var terminalShellOverride: String {
        string(for: terminalShellOverrideKey, defaultValue: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var rightClickOpensTerminals: Bool {
        bool(for: rightClickOpensTerminalsKey, defaultValue: true)
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

    private static func integer(for key: String, defaultValue: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }

        return UserDefaults.standard.integer(forKey: key)
    }

    private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}
