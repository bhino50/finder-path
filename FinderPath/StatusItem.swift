import AppKit

@MainActor
final class StatusItemController: NSObject {
    var onOpenWelcomeGuide: (() -> Void)?

    private let state = FinderPathState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindowController: SettingsWindowController?
    private var remoteConnectionWindowController: RemoteConnectionWindowController?
    private var copyConfirmationTask: Task<Void, Never>?

    // Lazy so the panel (and its views) only exist once terminals are used.
    // New sessions start in the current Finder folder when it is a real path,
    // falling back to home when Finder has no usable selection.
    private lazy var terminalPanelController = TerminalPanelController(
        store: .shared,
        newSessionDirectory: { [weak self] in
            guard let self, self.state.hasCopyablePath else { return NSHomeDirectory() }
            return self.state.currentPath
        }
    )

    private static let copyConfirmationNanoseconds: UInt64 = 1_000_000_000

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
        // Right-click goes straight to the terminal panel (the button sends
        // rightMouseUp); refresh keeps the new-session directory current.
        if FinderPathPreferences.rightClickOpensTerminals,
           NSApp.currentEvent?.type == .rightMouseUp {
            state.refresh()
            terminalPanelController.toggle(relativeTo: sender)
            return
        }

        // The Finder query runs off the main thread; the menu opens instantly
        // with the last-known path (or a fetching placeholder) and updates in
        // place when the result lands — NSMenu supports mutation while open.
        // A beachballed Finder can no longer freeze the click.
        state.refresh { [weak self] in
            guard let self else { return }
            self.rebuildMenu(self.menu)
        }
        rebuildMenu(menu)
        sender.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        sender.highlight(false)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let isPermissionDenied = FinderBridge.isPermissionDenied(state.currentPath)

        if FinderPathPreferences.showPathHeader {
            let pathItem = NSMenuItem()
            pathItem.view = PathMenuHeaderView(
                path: isPermissionDenied
                    ? "Finder access needed"
                    : FinderPathPreferences.displayPath(for: state.currentPath),
                // An empty path means the fetch is still in flight — show the
                // placeholder in the normal color, not as an error.
                isError: !state.currentPath.isEmpty && !state.hasCopyablePath
            )
            menu.addItem(pathItem)
            menu.addItem(.separator())
        }

        if isPermissionDenied {
            let permissionItem = NSMenuItem(
                title: "Allow Finder Access in System Settings…",
                action: #selector(openAutomationSettingsMenuItem),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsMenuItem), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let welcomeItem = NSMenuItem(title: "Setup Guide...", action: #selector(openWelcomeGuideMenuItem), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

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

        if FinderPathPreferences.showTerminalsSection {
            menu.addItem(.separator())

            for session in TerminalSessionStore.shared.sessions {
                let indicator = session.status == .running ? "\u{25CF} " : "\u{25CB} "
                let sessionItem = NSMenuItem(title: indicator + session.displayName, action: nil, keyEquivalent: "")
                sessionItem.toolTip = session.workingDirectory
                sessionItem.submenu = makeSessionSubmenu(for: session)
                menu.addItem(sessionItem)
            }

            let newTerminalItem = NSMenuItem(
                title: "New Terminal Here",
                action: #selector(newTerminalHereMenuItem),
                keyEquivalent: ""
            )
            newTerminalItem.target = self
            newTerminalItem.isEnabled = state.hasCopyablePath
            menu.addItem(newTerminalItem)

            let showTerminalsItem = NSMenuItem(
                title: "Show Terminals",
                action: #selector(showTerminalsMenuItem),
                keyEquivalent: ""
            )
            showTerminalsItem.target = self
            menu.addItem(showTerminalsItem)
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
        // Leave the temporary copy confirmation on screen; it restores the
        // configured appearance itself once it expires.
        guard copyConfirmationTask == nil else { return }
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

        settingsWindowController?.presentOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openRemoteConnectionWindow() {
        if remoteConnectionWindowController == nil {
            remoteConnectionWindowController = RemoteConnectionWindowController()
        }

        remoteConnectionWindowController?.presentOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWelcomeGuideMenuItem() {
        onOpenWelcomeGuide?()
    }

    @objc private func openAutomationSettingsMenuItem() {
        FinderBridge.openAutomationSettings()
    }

    @objc private func openSettingsMenuItem() {
        openSettings()
    }

    @objc private func refreshMenuItem() {
        state.refresh()
    }

    @objc private func copyPathMenuItem() {
        guard state.hasCopyablePath else { return }

        state.copyCurrentPath()
        showCopyConfirmation()
    }

    @objc private func copyCDMenuItem() {
        guard state.hasCopyablePath else { return }

        state.copyChangeDirectoryCommand()
        showCopyConfirmation()
    }

    // Briefly swaps the status icon for a checkmark so copy actions give
    // visible feedback, then restores the configured appearance.
    private func showCopyConfirmation() {
        guard let button = statusItem.button else { return }

        copyConfirmationTask?.cancel()

        if let checkmark = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Copied") {
            checkmark.isTemplate = true
            button.image = checkmark
        }

        copyConfirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.copyConfirmationNanoseconds)
            guard !Task.isCancelled else { return }

            self?.copyConfirmationTask = nil
            self?.updateStatusItemAppearance()
        }
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

    // Each session gets a submenu so it can be shown, renamed, or closed
    // without leaving the menu bar.
    private func makeSessionSubmenu(for session: TerminalSession) -> NSMenu {
        let submenu = NSMenu()

        let showItem = NSMenuItem(title: "Show Terminal", action: #selector(showTerminalSessionMenuItem(_:)), keyEquivalent: "")
        showItem.target = self
        showItem.representedObject = session
        submenu.addItem(showItem)

        submenu.addItem(.separator())

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(renameTerminalSessionMenuItem(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = session
        submenu.addItem(renameItem)

        let closeItem = NSMenuItem(title: "Close Terminal", action: #selector(closeTerminalSessionMenuItem(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = session
        submenu.addItem(closeItem)

        return submenu
    }

    @objc private func showTerminalSessionMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession,
              let button = statusItem.button else { return }

        terminalPanelController.show(session: session, relativeTo: button)
    }

    @objc private func renameTerminalSessionMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        guard let newName = TerminalRenamePrompt.run(currentName: session.name) else { return }
        TerminalSessionStore.shared.rename(session, to: newName)
    }

    @objc private func closeTerminalSessionMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        TerminalSessionStore.shared.remove(session)
    }

    @objc private func newTerminalHereMenuItem() {
        guard let button = statusItem.button else { return }

        let directory = state.hasCopyablePath ? state.currentPath : NSHomeDirectory()
        let session = TerminalSessionStore.shared.newSession(name: nil, workingDirectory: directory)
        terminalPanelController.show(session: session, relativeTo: button)
    }

    @objc private func showTerminalsMenuItem() {
        guard let button = statusItem.button else { return }

        terminalPanelController.toggle(relativeTo: button)
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
        pathLabel.toolTip = path
        pathLabel.setAccessibilityLabel(FinderPathPreferences.menuHeaderTitle)
        pathLabel.setAccessibilityValue(path)
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
