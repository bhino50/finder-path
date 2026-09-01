import AppKit

@MainActor
final class StatusItemController: NSObject {
    private struct HarnessMenuItemBinding {
        let item: NSMenuItem
        let name: String
        let externalAction: Selector
        let terminalAction: Selector
    }

    var onOpenWelcomeGuide: (() -> Void)?

    private let state = FinderPathState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindowController: SettingsWindowController?
    private var remoteConnectionWindowController: RemoteConnectionWindowController?
    private var copyConfirmationTask: Task<Void, Never>?
    private var isMenuTracking = false
    private var menuOptionHeld = false
    private var harnessMenuItemBindings: [HarnessMenuItemBinding] = []
    private var hoverDwellTimer: Timer?

    // Hovering the status item quick-picks an open terminal session without a
    // click. Lazy so the picker only exists once a hover actually qualifies.
    private lazy var hoverPicker: TerminalHoverPickerController = {
        let picker = TerminalHoverPickerController(store: .shared)
        picker.onOpenSession = { [weak self] session in self?.openTerminal(session) }
        picker.onCloseSession = { [weak self] session in self?.closeTerminal(session) }
        return picker
    }()

    private static let hoverDwellSeconds: TimeInterval = 0.45

    // Lazy so the panel (and its views) only exist once terminals are used.
    // New sessions start in the current Finder folder when it is a real path,
    // falling back to home when Finder has no usable selection.
    private lazy var terminalPanelController = TerminalPanelController(
        store: .shared,
        newSessionDirectory: { [weak self] in
            guard let self else { return nil }
            // A right-click shows the panel and starts a refresh at the same
            // time; read the folder only once that refresh has settled.
            await self.state.waitForRefresh()
            let candidate = self.state.hasCopyablePath
                ? self.state.actionTargetCandidate()
                : NSHomeDirectory()
            return await self.state.validatedActionTarget(candidate)
        }
    )

    private static let copyConfirmationNanoseconds: UInt64 = 1_000_000_000

    private static let recentPathActions = RecentPathActions(
        copyPath: #selector(copyRecentPathMenuItem(_:)),
        copyCDCommand: #selector(copyRecentCDCommandMenuItem(_:)),
        openInCmux: #selector(openRecentInCmuxMenuItem(_:)),
        openInGhostty: #selector(openRecentInGhosttyMenuItem(_:)),
        openInTerminal: #selector(openRecentInTerminalMenuItem(_:)),
        openWithAgent: #selector(openRecentWithAgentMenuItem(_:)),
        openAgentInTerminal: #selector(openRecentAgentInTerminalMenuItem(_:)),
        newTerminal: #selector(newTerminalAtRecentPathMenuItem(_:)),
        revealInFinder: #selector(revealRecentPathMenuItem(_:)),
        clear: #selector(clearRecentPathsMenuItem)
    )

    override init() {
        super.init()

        // NSStatusItem keeps FinderPath as a lightweight native menu bar utility
        // while allowing custom click timing so the menu does not drag with the cursor.
        if let button = statusItem.button {
            button.toolTip = "FinderPath"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Hover detection for the terminal quick-pick. The dwell delay in
            // scheduleHoverPicker keeps a pointer merely crossing the menu bar
            // from summoning the popover.
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
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

    // NSTrackingArea sends mouseEntered:/mouseExited: to its owner even when
    // the owner is not an NSResponder; the explicit selector names keep the
    // Swift methods reachable from that dispatch.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        scheduleHoverPicker()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }

    private func scheduleHoverPicker() {
        hoverDwellTimer?.invalidate()
        let timer = Timer(timeInterval: Self.hoverDwellSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.presentHoverPickerIfAllowed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverDwellTimer = timer
    }

    private func presentHoverPickerIfAllowed() {
        hoverDwellTimer = nil
        guard let button = statusItem.button else { return }
        // Session count gates first so an idle hover never lazily builds the
        // terminal panel just to ask whether it is visible.
        let sessionCount = TerminalSessionStore.shared.sessions.count
        guard sessionCount > 0 else { return }
        guard HoverPickerLogic.shouldPresent(
            enabled: FinderPathPreferences.hoverShowsTerminals,
            sessionCount: sessionCount,
            isMenuTracking: isMenuTracking,
            isPanelVisible: terminalPanelController.isPresenting || hoverPicker.isShown
        ) else { return }
        hoverPicker.present(relativeTo: button)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // A click supersedes any hover-summoned quick-pick.
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
        hoverPicker.dismiss()

        // Right-click goes straight to the terminal panel (the button sends
        // rightMouseUp). The refresh runs alongside the panel, not ahead of
        // it: a stalled Finder query can take its whole timeout, and the
        // panel must not wait on that. newSessionDirectory waits instead, so
        // a session created for this panel still gets the live folder.
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
        menuOptionHeld = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.option)
        isMenuTracking = true
        state.refresh { [weak self] in
            self?.rebuildTrackedMenuIfNeeded()
        }
        rebuildMenu(menu, optionHeld: menuOptionHeld)

        // NSMenu.popUp runs its own tracking loop that bypasses local
        // flagsChanged monitors, so poll the current modifier state while the
        // menu is visible. The menu's tracking mode is NOT .eventTracking — it
        // is one of the common modes — so the timer must be scheduled in
        // .common or it never fires during tracking (Option would then only swap
        // when held before the menu opens, not while it is already open).
        let modifierPollingTimer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(pollMenuModifierFlags(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(modifierPollingTimer, forMode: .common)

        defer {
            isMenuTracking = false
            modifierPollingTimer.invalidate()
        }
        sender.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        sender.highlight(false)
    }

    @objc private func pollMenuModifierFlags(_: Timer) {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        guard optionHeld != menuOptionHeld else { return }
        menuOptionHeld = optionHeld
        updateHarnessMenuItems(optionHeld: optionHeld)
    }

    private func rebuildTrackedMenuIfNeeded() {
        guard isMenuTracking else { return }
        // Re-read the live modifier state: a refresh rebuild runs mid-track, so
        // stale state would put agent rows back into the wrong launch mode.
        menuOptionHeld = NSEvent.modifierFlags.contains(.option)
        rebuildMenu(menu, optionHeld: menuOptionHeld)
    }

    /// The agents the menu may offer, in display order. Availability stats every
    /// directory on PATH, so it is resolved here once per rebuild and handed to
    /// every row that needs it — doing it per row would mean hundreds of
    /// filesystem calls each time the menu is built, twice per click.
    private func agentOptions() -> [RecentPathAgentOption] {
        [
            ("Codex", FinderPathPreferences.codexExecutable, FinderPathPreferences.showOpenWithCodexItem),
            ("Claude", FinderPathPreferences.claudeExecutable, FinderPathPreferences.showOpenWithClaudeItem),
            ("Hermes", FinderPathPreferences.hermesExecutable, FinderPathPreferences.showOpenWithHermesItem)
        ].map { name, executable, isEnabled in
            RecentPathAgentOption(
                name: name,
                executable: executable,
                availability: AgentLauncher.availability(for: executable),
                isEnabled: isEnabled
            )
        }
    }

    private func rebuildMenu(_ menu: NSMenu, optionHeld: Bool) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        harnessMenuItemBindings.removeAll(keepingCapacity: true)

        let isPermissionDenied = FinderBridge.isPermissionDenied(state.currentPath)
        let agents = agentOptions()
        let launcherAvailability = RecentPathLauncherAvailability(
            isCmuxInstalled: TerminalBridge.isCmuxInstalled,
            isGhosttyInstalled: TerminalBridge.isGhosttyInstalled
        )

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
            let isInstalled = launcherAvailability.isCmuxInstalled
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
            let isInstalled = launcherAvailability.isGhosttyInstalled
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

        // Each agent launcher opens an external terminal by default; holding
        // Option swaps each launcher to run the agent inside the built-in
        // FinderPath terminal. Menus shown with popUp do not drive AppKit's
        // live alternate-item swap, so statusItemClicked polls the modifier
        // state and updates these rows while the menu is open.
        func addHarnessItem(_ agent: RecentPathAgentOption, externalAction: Selector, terminalAction: Selector) {
            guard agent.isEnabled else { return }
            guard !hideUnavailableAgents || agent.availability.isInstalled else { return }
            addPendingLauncherSeparator()
            guard agent.availability.isInstalled else {
                let item = NSMenuItem(title: "\(agent.name) Not Installed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }
            let presentation = AgentLauncher.menuPresentation(name: agent.name, optionHeld: optionHeld)
            let action = presentation.usesBuiltInTerminal ? terminalAction : externalAction
            let item = NSMenuItem(title: presentation.title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = state.hasCopyablePath
            menu.addItem(item)
            harnessMenuItemBindings.append(
                HarnessMenuItemBinding(
                    item: item,
                    name: agent.name,
                    externalAction: externalAction,
                    terminalAction: terminalAction
                )
            )
        }

        addHarnessItem(
            agents[0],
            externalAction: #selector(openWithCodexMenuItem),
            terminalAction: #selector(openCodexInTerminalMenuItem)
        )
        addHarnessItem(
            agents[1],
            externalAction: #selector(openWithClaudeMenuItem),
            terminalAction: #selector(openClaudeInTerminalMenuItem)
        )
        addHarnessItem(
            agents[2],
            externalAction: #selector(openWithHermesMenuItem),
            terminalAction: #selector(openHermesInTerminalMenuItem)
        )

        if FinderPathPreferences.showRecentPathsItem,
           let recentPathsMenu = RecentPathsMenu.makeMenu(
               paths: RecentPathsStore.shared.paths,
               launchers: launcherAvailability,
               agents: agents,
               hideUnavailableAgents: hideUnavailableAgents,
               optionHeld: optionHeld,
               target: self,
               actions: Self.recentPathActions,
               registerAgentItem: { [weak self] item, agent in
                   self?.harnessMenuItemBindings.append(
                       HarnessMenuItemBinding(
                           item: item,
                           name: agent.name,
                           externalAction: Self.recentPathActions.openWithAgent,
                           terminalAction: Self.recentPathActions.openAgentInTerminal
                       )
                   )
               }
           ) {
            menu.addItem(.separator())
            let recentPathsItem = NSMenuItem(title: "Recent Paths", action: nil, keyEquivalent: "")
            recentPathsItem.submenu = recentPathsMenu
            menu.addItem(recentPathsItem)
        }

        if FinderPathPreferences.showTerminalsSection {
            menu.addItem(.separator())

            for session in TerminalSessionStore.shared.sessions {
                let sessionItem = NSMenuItem()
                let row = TerminalMenuRowView(name: session.displayName)
                row.onOpen = { [weak self] in
                    menu.cancelTracking()
                    self?.openTerminal(session)
                }
                row.onClose = { [weak self] in
                    menu.cancelTracking()
                    self?.closeTerminal(session)
                }
                sessionItem.view = row
                sessionItem.toolTip = session.workingDirectory
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

    private func updateHarnessMenuItems(optionHeld: Bool) {
        for binding in harnessMenuItemBindings {
            let presentation = AgentLauncher.menuPresentation(
                name: binding.name,
                optionHeld: optionHeld
            )
            binding.item.title = presentation.title
            binding.item.action = presentation.usesBuiltInTerminal
                ? binding.terminalAction
                : binding.externalAction
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
        state.refresh { [weak self] in
            self?.rebuildTrackedMenuIfNeeded()
        }
        // begin() retires the prior actionable path synchronously. Reflect that
        // loading state immediately so the visible header and enabled actions
        // can never describe different folders while Finder is responding.
        rebuildTrackedMenuIfNeeded()
    }

    @objc private func copyPathMenuItem() {
        guard state.hasCopyablePath else { return }

        state.copyCurrentPath { [weak self] in self?.showCopyConfirmation() }
    }

    @objc private func copyCDMenuItem() {
        guard state.hasCopyablePath else { return }

        state.copyChangeDirectoryCommand { [weak self] in self?.showCopyConfirmation() }
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
        state.openWithAgent(named: "Codex", executable: FinderPathPreferences.codexExecutable)
    }

    @objc private func openWithClaudeMenuItem() {
        state.openWithAgent(named: "Claude", executable: FinderPathPreferences.claudeExecutable)
    }

    @objc private func openWithHermesMenuItem() {
        state.openWithAgent(named: "Hermes", executable: FinderPathPreferences.hermesExecutable)
    }

    // Clicking a terminal row opens it directly; the row's trailing button
    // closes it. Renaming lives on the panel tab (double- or right-click).
    // The popover is presented on the next runloop tick so the menu has fully
    // dismissed first — a popover shown mid-menu-teardown anchors to the wrong
    // place and loses its beak.
    private func openTerminal(_ session: TerminalSession) {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async { [weak self] in
            self?.terminalPanelController.show(session: session, relativeTo: button)
        }
    }

    private func closeTerminal(_ session: TerminalSession) {
        TerminalSessionStore.shared.remove(session)
    }

    /// Opens a new built-in terminal that runs the given agent command once the
    /// shell is ready. A nil directory means the current Finder folder; recent
    /// path rows pass their own.
    private func openHarnessTerminal(executable: String, name: String, directory: String? = nil) {
        guard let button = statusItem.button else { return }
        guard let resolvedPath = AgentLauncher.availability(for: executable).resolvedPath else {
            FinderPathAlertPresenter.presentLaunchFailure(
                "\(name) CLI was not found. Check its command or path in FinderPath Settings.",
                displayName: name
            )
            return
        }
        let requestedDirectory = directory ?? (state.hasCopyablePath ? state.currentPath : NSHomeDirectory())
        state.withResolvedActionTarget(requestedDirectory) { [weak self, weak button] workingDirectory in
            guard let self, let button else { return }
            let session = TerminalSessionStore.shared.newSession(
                name: name,
                workingDirectory: workingDirectory,
                initialCommand: ShellCommand.argument(resolvedPath)
            )
            DispatchQueue.main.async { [weak self, weak button] in
                guard let button else { return }
                self?.terminalPanelController.show(session: session, relativeTo: button)
            }
        }
    }

    @objc private func openCodexInTerminalMenuItem() {
        openHarnessTerminal(executable: FinderPathPreferences.codexExecutable, name: "Codex")
    }

    @objc private func openClaudeInTerminalMenuItem() {
        openHarnessTerminal(executable: FinderPathPreferences.claudeExecutable, name: "Claude")
    }

    @objc private func openHermesInTerminalMenuItem() {
        openHarnessTerminal(executable: FinderPathPreferences.hermesExecutable, name: "Hermes")
    }

    @objc private func newTerminalHereMenuItem() {
        guard let button = statusItem.button else { return }

        let requestedDirectory = state.hasCopyablePath ? state.currentPath : NSHomeDirectory()
        state.withResolvedActionTarget(requestedDirectory) { [weak self, weak button] directory in
            guard let self, let button else { return }
            let session = TerminalSessionStore.shared.newSession(name: nil, workingDirectory: directory)
            self.terminalPanelController.show(session: session, relativeTo: button)
        }
    }

    @objc private func showTerminalsMenuItem() {
        guard let button = statusItem.button else { return }

        terminalPanelController.toggle(relativeTo: button)
    }

    // MARK: - Recent path actions
    //
    // Non-agent rows carry their folder as a String representedObject; agent
    // rows carry a RecentPathAgentTarget. A row whose object is missing or of
    // the wrong type is ignored rather than falling back to the current Finder
    // path, which would silently act on the wrong folder.

    @objc private func copyRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.copyCurrentPath(at: path) { [weak self] in self?.showCopyConfirmation() }
    }

    @objc private func copyRecentCDCommandMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.copyChangeDirectoryCommand(at: path) { [weak self] in self?.showCopyConfirmation() }
    }

    @objc private func openRecentInCmuxMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInCmux(at: path)
    }

    @objc private func openRecentInGhosttyMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInGhostty(at: path)
    }

    @objc private func openRecentInTerminalMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInTerminal(at: path)
    }

    @objc private func openRecentWithAgentMenuItem(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? RecentPathAgentTarget else { return }
        state.openWithAgent(named: agent.name, executable: agent.executable, at: agent.path)
    }

    @objc private func openRecentAgentInTerminalMenuItem(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? RecentPathAgentTarget else { return }
        openHarnessTerminal(executable: agent.executable, name: agent.name, directory: agent.path)
    }

    @objc private func newTerminalAtRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let button = statusItem.button else { return }
        state.withResolvedActionTarget(path) { [weak self, weak button] directory in
            guard let self, let button else { return }
            let session = TerminalSessionStore.shared.newSession(name: nil, workingDirectory: directory)
            self.terminalPanelController.show(session: session, relativeTo: button)
        }
    }

    @objc private func revealRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.revealInFinder(at: path)
    }

    @objc private func clearRecentPathsMenuItem() {
        RecentPathsStore.shared.clear()
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
