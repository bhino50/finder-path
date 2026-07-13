import AppKit

// Combined terminal UI: a session tab strip above a TerminalView, presented
// either as a transient popover anchored to the status item or, when pinned,
// as a floating utility panel. Closing either container only hides the UI;
// sessions and their PTYs are owned by the store and keep running.

@MainActor
final class TerminalPanelController: NSObject, NSPopoverDelegate {
    private enum Layout {
        static let defaultSize = NSSize(width: 640, height: 420)
        static let minimumSize = NSSize(width: 380, height: 240)
        static let topBarHeight: CGFloat = 28
        static let topBarSpacing: CGFloat = 4
        static let topBarInset: CGFloat = 6
        static let tabSpacing: CGFloat = 2
        static let dotFontSize: CGFloat = 6
        static let dotBaselineOffset: CGFloat = 1
        static let tabFontSize: CGFloat = 11
        static let closeSymbolPointSize: CGFloat = 8
    }

    private static let popoverWidthKey = "TerminalPanelPopoverWidth"
    private static let popoverHeightKey = "TerminalPanelPopoverHeight"
    private static let panelFrameAutosaveName = "TerminalPanel"
    private static let panelTitle = "FinderPath Terminals"

    private let store: TerminalSessionStore
    private let newSessionDirectory: () -> String

    /// True while the content lives in the floating panel instead of the popover.
    private(set) var isPinned = false

    private let contentView = NSView()
    private let terminalView = TerminalView(frame: .zero)
    private let tabsStack = NSStackView()
    private let restartButton = NSButton()
    private let pinButton = NSButton()

    private var popover: NSPopover?
    private var panel: NSPanel?
    private var activeSessionID: UUID?
    /// Anchor for re-showing the popover after unpinning. Held weakly so the
    /// panel never keeps status bar machinery alive.
    private weak var lastStatusButton: NSStatusBarButton?

    init(store: TerminalSessionStore, newSessionDirectory: @escaping () -> String) {
        self.store = store
        self.newSessionDirectory = newSessionDirectory
        super.init()
        buildContentView()
        // The panel owns the store's change callback and every session's
        // onStatusChange. TerminalView deliberately uses only onScreenUpdate,
        // so the two layers never clobber each other's handlers.
        store.onChange = { [weak self] in self?.storeDidChange() }
        storeDidChange()
    }

    // MARK: - Presentation

    func toggle(relativeTo statusButton: NSStatusBarButton) {
        lastStatusButton = statusButton
        if isPinned {
            togglePanel()
            return
        }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        presentPopover(relativeTo: statusButton)
    }

    func show(session: TerminalSession, relativeTo statusButton: NSStatusBarButton) {
        lastStatusButton = statusButton
        activeSessionID = session.id
        if isPinned {
            presentPanel()
        } else if popover?.isShown == true {
            activate(session)
        } else {
            presentPopover(relativeTo: statusButton)
        }
    }

    private func presentPopover(relativeTo statusButton: NSStatusBarButton) {
        let popover = ensurePopover()
        activateCurrentOrFirstSession()
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        terminalView.focusTerminal()
    }

    private func presentPanel() {
        let panel = ensurePanel()
        if panel.contentView !== contentView {
            contentView.removeFromSuperview()
            panel.contentView = contentView
        }
        activateCurrentOrFirstSession()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        terminalView.focusTerminal()
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            // Hiding, not closing: sessions keep running in the store.
            panel.orderOut(nil)
            return
        }
        presentPanel()
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        contentView.removeFromSuperview()
        contentView.frame = NSRect(origin: .zero, size: storedPopoverSize())
        let viewController = NSViewController()
        viewController.view = contentView
        let created = NSPopover()
        created.behavior = .transient
        created.contentViewController = viewController
        created.contentSize = contentView.frame.size
        created.delegate = self
        popover = created
        return created
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        created.title = Self.panelTitle
        created.level = .floating
        created.hidesOnDeactivate = false
        // The close button must only hide the panel; releasing it would tear
        // down the content view while sessions are still running.
        created.isReleasedWhenClosed = false
        created.contentMinSize = Layout.minimumSize
        created.center()
        created.setFrameAutosaveName(Self.panelFrameAutosaveName)
        panel = created
        return created
    }

    // MARK: - Pinning

    @objc private func pinClicked(_ sender: NSButton) {
        isPinned ? unpin() : pin()
    }

    private func pin() {
        persistPopoverSize()
        popover?.performClose(nil)
        popover = nil
        isPinned = true
        updatePinButton()
        presentPanel()
    }

    private func unpin() {
        if let panel {
            panel.orderOut(nil)
            // Detach the content so the popover can adopt it again.
            panel.contentView = NSView()
        }
        isPinned = false
        updatePinButton()
        if let statusButton = lastStatusButton {
            presentPopover(relativeTo: statusButton)
        }
    }

    // MARK: - Popover size persistence

    func popoverDidClose(_ notification: Notification) {
        persistPopoverSize()
    }

    private func storedPopoverSize() -> NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: Self.popoverWidthKey)
        let height = defaults.double(forKey: Self.popoverHeightKey)
        guard width > 0, height > 0 else { return Layout.defaultSize }
        return NSSize(
            width: max(width, Layout.minimumSize.width),
            height: max(height, Layout.minimumSize.height)
        )
    }

    private func persistPopoverSize() {
        guard !isPinned else { return }
        let size = contentView.frame.size
        guard size.width >= Layout.minimumSize.width,
              size.height >= Layout.minimumSize.height else { return }
        UserDefaults.standard.set(Double(size.width), forKey: Self.popoverWidthKey)
        UserDefaults.standard.set(Double(size.height), forKey: Self.popoverHeightKey)
    }

    // MARK: - Session activation

    private var activeSession: TerminalSession? {
        guard let activeSessionID else { return store.sessions.first }
        return store.sessions.first { $0.id == activeSessionID } ?? store.sessions.first
    }

    private var isPresented: Bool {
        isPinned ? (panel?.isVisible ?? false) : (popover?.isShown ?? false)
    }

    private func activate(_ session: TerminalSession) {
        activeSessionID = session.id
        session.start()
        terminalView.session = session
        terminalView.focusTerminal()
        rebuildTabs()
        updateRestartButton()
    }

    private func activateCurrentOrFirstSession() {
        if let session = activeSession {
            activate(session)
            return
        }
        terminalView.session = nil
        rebuildTabs()
        updateRestartButton()
    }

    // MARK: - Store and status wiring

    private func storeDidChange() {
        for session in store.sessions {
            session.onStatusChange = { [weak self] in self?.sessionStatusDidChange() }
        }
        normalizeActiveSession()
        rebuildTabs()
        updateRestartButton()
    }

    /// Keeps the active id pointing at a live session after removals; when
    /// the UI is visible the replacement session is activated so the pane
    /// never shows a removed session's screen.
    private func normalizeActiveSession() {
        if let activeSessionID, store.sessions.contains(where: { $0.id == activeSessionID }) {
            return
        }
        activeSessionID = store.sessions.first?.id
        guard isPresented else { return }
        if let session = activeSession {
            activate(session)
        } else {
            terminalView.session = nil
        }
    }

    private func sessionStatusDidChange() {
        rebuildTabs()
        updateRestartButton()
        // TerminalView repaints from onScreenUpdate only; status transitions
        // (exit rows appearing, restarts clearing them) repaint from here.
        terminalView.needsDisplay = true
    }

    // MARK: - Actions

    @objc private func tabClicked(_ sender: NSButton) {
        guard store.sessions.indices.contains(sender.tag) else { return }
        activate(store.sessions[sender.tag])
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        guard store.sessions.indices.contains(sender.tag) else { return }
        close(store.sessions[sender.tag])
    }

    @objc private func newSessionClicked(_ sender: NSButton) {
        activate(store.newSession(name: nil, workingDirectory: newSessionDirectory()))
    }

    @objc private func restartClicked(_ sender: NSButton) {
        activeSession?.restart()
    }

    private func close(_ session: TerminalSession) {
        // Choose the successor before removing so the store's onChange
        // callback never observes an active id pointing at a dead session.
        if activeSessionID == session.id {
            activeSessionID = store.sessions.first { $0 !== session }?.id
        }
        store.remove(session)
        if let next = activeSession {
            activate(next)
        } else {
            terminalView.session = nil
            rebuildTabs()
            updateRestartButton()
        }
    }

    // MARK: - Content layout

    private func buildContentView() {
        contentView.frame = NSRect(origin: .zero, size: storedPopoverSize())
        terminalView.fontSize = CGFloat(FinderPathPreferences.terminalFontSize)

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = Layout.topBarSpacing
        topBar.edgeInsets = NSEdgeInsets(top: 0, left: Layout.topBarInset, bottom: 0, right: Layout.topBarInset)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = Layout.tabSpacing

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let plusButton = Self.makeBarButton(symbol: "plus", fallbackTitle: "+", accessibilityDescription: "New Terminal")
        plusButton.target = self
        plusButton.action = #selector(newSessionClicked(_:))
        plusButton.toolTip = "New terminal in the current Finder folder"

        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        restartButton.target = self
        restartButton.action = #selector(restartClicked(_:))
        restartButton.isHidden = true

        pinButton.isBordered = false
        pinButton.setButtonType(.momentaryChange)
        pinButton.target = self
        pinButton.action = #selector(pinClicked(_:))
        updatePinButton()

        topBar.addArrangedSubview(tabsStack)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(plusButton)
        topBar.addArrangedSubview(restartButton)
        topBar.addArrangedSubview(pinButton)

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)
        contentView.addSubview(terminalView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Layout.topBarHeight),
            terminalView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Tab strip

    private func rebuildTabs() {
        for view in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let active = activeSession
        for (index, session) in store.sessions.enumerated() {
            let isActive = session === active
            tabsStack.addArrangedSubview(makeTabButton(for: session, at: index, isActive: isActive))
            if isActive {
                tabsStack.addArrangedSubview(makeCloseButton(at: index))
            }
        }
    }

    private func makeTabButton(for session: TerminalSession, at index: Int, isActive: Bool) -> NSButton {
        let button = TerminalTabButton(title: "", target: self, action: #selector(tabClicked(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.tag = index
        button.attributedTitle = Self.tabTitle(name: session.name, status: session.status, isActive: isActive)
        button.toolTip = session.workingDirectory
        button.onRightClick = { [weak self] in self?.close(session) }
        return button
    }

    private func makeCloseButton(at index: Int) -> NSButton {
        let button = Self.makeBarButton(symbol: "xmark", fallbackTitle: "x", accessibilityDescription: "Close Terminal")
        if let image = button.image {
            let configuration = NSImage.SymbolConfiguration(pointSize: Layout.closeSymbolPointSize, weight: .regular)
            button.image = image.withSymbolConfiguration(configuration) ?? image
        }
        button.tag = index
        button.target = self
        button.action = #selector(closeTabClicked(_:))
        button.toolTip = "Close this terminal session"
        return button
    }

    /// Dot + name rendered as one attributed title: a 6pt U+25CF indicator
    /// (green while running, dimmed otherwise) leading the session name.
    private static func tabTitle(name: String, status: TerminalSession.Status, isActive: Bool) -> NSAttributedString {
        let dotColor: NSColor = status == .running ? .systemGreen : .tertiaryLabelColor
        let title = NSMutableAttributedString(string: "\u{25CF} ", attributes: [
            .font: NSFont.systemFont(ofSize: Layout.dotFontSize),
            .foregroundColor: dotColor,
            .baselineOffset: Layout.dotBaselineOffset,
        ])
        let nameFont = isActive
            ? NSFont.boldSystemFont(ofSize: Layout.tabFontSize)
            : NSFont.systemFont(ofSize: Layout.tabFontSize)
        title.append(NSAttributedString(string: name, attributes: [
            .font: nameFont,
            .foregroundColor: NSColor.labelColor,
        ]))
        return title
    }

    // MARK: - Button helpers

    private func updateRestartButton() {
        switch activeSession?.status {
        case .exited, .failed:
            restartButton.isHidden = false
        case .running, .notStarted, nil:
            restartButton.isHidden = true
        }
    }

    private func updatePinButton() {
        let symbol = isPinned ? "pin.fill" : "pin"
        let description = isPinned ? "Unpin Terminals" : "Pin Terminals"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if pinButton.image == nil {
            pinButton.title = "Pin"
        }
        pinButton.toolTip = isPinned
            ? "Return terminals to the menu bar popover"
            : "Pin terminals as a floating window"
    }

    private static func makeBarButton(symbol: String, fallbackTitle: String, accessibilityDescription: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription) {
            button.image = image
        } else {
            button.title = fallbackTitle
        }
        return button
    }
}

/// Borderless tab button that also reports right-clicks, so a tab can be
/// closed without reaching for its close button.
private final class TerminalTabButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseUp(with event: NSEvent) {
        guard let onRightClick else {
            super.rightMouseUp(with: event)
            return
        }
        onRightClick()
    }
}
