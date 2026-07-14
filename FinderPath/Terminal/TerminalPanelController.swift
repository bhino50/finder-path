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
        static let maximumSize = NSSize(width: 1600, height: 1100)
        static let gripSize: CGFloat = 16
        static let maxTabWidth: CGFloat = 160
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

    /// True while the content lives in the resizable floating window instead of
    /// the popover. The window is the default surface so the terminal resizes
    /// from every edge; unpinning returns to the menu-bar popover.
    private(set) var isPinned = true

    private let contentView = NSView()
    private let terminalView = TerminalView(frame: .zero)
    private let tabsStack = NSStackView()
    private let restartButton = NSButton()
    private let pinButton = NSButton()
    private let closePanelButton = NSButton()
    private let resizeGrip = ResizeGripView()

    private var popover: NSPopover?
    private var panel: NSPanel?
    private var defaultsObserver: NSObjectProtocol?
    private var activeSessionID: UUID?
    /// Anchor for re-showing the popover after unpinning. Held weakly so the
    /// panel never keeps status bar machinery alive.
    private weak var lastStatusButton: NSStatusBarButton?
    /// The panel is auto-placed near the menu bar only on its first appearance;
    /// after that the user's position (and window autosave) win.
    private var hasPositionedPanel = false

    init(store: TerminalSessionStore, newSessionDirectory: @escaping () -> String) {
        self.store = store
        self.newSessionDirectory = newSessionDirectory
        super.init()
        buildContentView()
        // The panel owns the store's change callback and every session's
        // onStatusChange. TerminalView deliberately uses only onScreenUpdate,
        // so the two layers never clobber each other's handlers.
        store.onChange = { [weak self] in self?.storeDidChange() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminalView.fontSize = CGFloat(FinderPathPreferences.terminalFontSize)
            }
        }
        storeDidChange()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
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
        // .applicationDefined popovers (unlike .transient) do not take key
        // focus on their own, so the app must be activated for the terminal to
        // receive keystrokes. No dismiss monitor is installed, so this does not
        // make the popover vanish on interaction.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        terminalView.focusTerminal()
    }

    private func presentPanel() {
        let panel = ensurePanel()
        if panel.contentView !== contentView {
            contentView.removeFromSuperview()
            panel.contentView = contentView
        }
        positionPanelIfNeeded(panel)
        activateCurrentOrFirstSession()
        NSApp.activate(ignoringOtherApps: true)
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

    /// Hides whichever surface is showing. Sessions keep running in the store,
    /// so reopening restores them.
    private func dismiss() {
        if isPinned {
            panel?.orderOut(nil)
        } else {
            popover?.performClose(nil)
        }
    }

    @objc private func closePanelClicked() {
        dismiss()
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        contentView.removeFromSuperview()
        contentView.frame = NSRect(origin: .zero, size: storedPopoverSize())
        let viewController = NSViewController()
        viewController.view = contentView
        let created = NSPopover()
        // .applicationDefined (not .transient) so typing Return or Escape in
        // the terminal does not dismiss the popover; we close it ourselves.
        created.behavior = .applicationDefined
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
        created.setFrameAutosaveName(Self.panelFrameAutosaveName)
        panel = created
        return created
    }

    /// Places the panel near the menu bar on its first show when the user has
    /// no saved window frame yet; a saved autosave frame always wins.
    private func positionPanelIfNeeded(_ panel: NSPanel) {
        guard !hasPositionedPanel else { return }
        hasPositionedPanel = true
        let autosaveKey = "NSWindow Frame \(Self.panelFrameAutosaveName)"
        guard UserDefaults.standard.string(forKey: autosaveKey) == nil else { return }
        guard let statusButton = lastStatusButton, let buttonWindow = statusButton.window else {
            panel.center()
            return
        }
        let buttonInScreen = buttonWindow.convertToScreen(statusButton.convert(statusButton.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        // Right edge under the status item, top just below the menu bar, clamped
        // to the visible screen.
        let originX = min(max(buttonInScreen.maxX - frame.width, visible.minX), visible.maxX - frame.width)
        let originY = max(buttonInScreen.minY - frame.height - 4, visible.minY)
        frame.origin = NSPoint(x: originX, y: originY)
        panel.setFrame(frame, display: false)
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
        // The floating panel resizes from its own edges, so the grip is only
        // for the popover.
        resizeGrip.isHidden = true
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
        resizeGrip.isHidden = false
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
        // Resolve Auto Layout before attaching a new session. Starting the PTY
        // at its 80x24 fallback and then briefly resizing it through a zero-size
        // view (2x10 after minimum clamping) makes zsh redraw its prompt at
        // conflicting widths. History recall then leaves the familiar "<..."
        // left-edge marker mixed into the prompt.
        contentView.layoutSubtreeIfNeeded()
        terminalView.session = session
        // TerminalView pushes the real grid size while the session is still
        // .notStarted, so the PTY is born at the correct dimensions and never
        // needs a startup SIGWINCH/redraw cycle.
        session.start()
        terminalView.focusTerminal()
        rebuildTabs()
        updateRestartButton()
    }

    private func activateCurrentOrFirstSession() {
        // Never present an empty window: if nothing is open, start a terminal
        // in the current Finder folder so there is always something to show.
        if store.sessions.isEmpty {
            _ = store.newSession(name: nil, workingDirectory: newSessionDirectory())
        }
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
            // Follow the shell title so the tab renames itself to the running task.
            session.onTitleChange = { [weak self] in self?.rebuildTabs() }
        }
        // Closing the last terminal dismisses the window rather than leaving an
        // empty shell on screen.
        if store.sessions.isEmpty && isPresented {
            dismiss()
            return
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
        plusButton.setAccessibilityLabel("New Terminal")

        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        restartButton.target = self
        restartButton.action = #selector(restartClicked(_:))
        restartButton.isHidden = true
        restartButton.setAccessibilityLabel("Restart Terminal")

        pinButton.isBordered = false
        pinButton.setButtonType(.momentaryChange)
        pinButton.target = self
        pinButton.action = #selector(pinClicked(_:))
        updatePinButton()

        closePanelButton.isBordered = false
        closePanelButton.setButtonType(.momentaryChange)
        closePanelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close terminals")
        if closePanelButton.image == nil { closePanelButton.title = "Close" }
        closePanelButton.contentTintColor = .secondaryLabelColor
        closePanelButton.target = self
        closePanelButton.action = #selector(closePanelClicked)
        closePanelButton.toolTip = "Close this window (terminals keep running in the background)"
        closePanelButton.setAccessibilityLabel("Close Terminal Window")

        topBar.addArrangedSubview(tabsStack)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(plusButton)
        topBar.addArrangedSubview(restartButton)
        topBar.addArrangedSubview(pinButton)
        topBar.addArrangedSubview(closePanelButton)

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)
        contentView.addSubview(terminalView)

        // Drag grip in the bottom-right corner resizes the popover. contentView
        // is not flipped, so the bottom edge is y == 0.
        resizeGrip.translatesAutoresizingMaskIntoConstraints = false
        resizeGrip.onResizeBegan = { [weak self] in
            self?.terminalView.beginInteractiveResize()
            return self?.contentView.frame.size ?? .zero
        }
        resizeGrip.onResize = { [weak self] size in self?.applyContentResize(size) }
        resizeGrip.onResizeEnded = { [weak self] in self?.terminalView.endInteractiveResize() }
        contentView.addSubview(resizeGrip)
        // The window resizes from its own edges, so the grip serves only the
        // popover; hide it while pinned (the default surface).
        resizeGrip.isHidden = isPinned

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Layout.topBarHeight),
            terminalView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeGrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            resizeGrip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeGrip.widthAnchor.constraint(equalToConstant: Layout.gripSize),
            resizeGrip.heightAnchor.constraint(equalToConstant: Layout.gripSize),
        ])
    }

    /// Applies a drag-resize to the popover, clamped to sane bounds. The
    /// terminal reflows to the new width via the view's layout pass, which
    /// pushes the new grid size to the PTY. The pinned panel resizes from its
    /// own edges, so the grip is hidden there.
    private func applyContentResize(_ requested: CGSize) {
        let clamped = NSSize(
            width: min(max(requested.width, Layout.minimumSize.width), Layout.maximumSize.width),
            height: min(max(requested.height, Layout.minimumSize.height), Layout.maximumSize.height)
        )
        // Drive the popover only; it resizes its content view and Auto Layout
        // lays out the subviews. Setting the content frame by hand as well
        // fights that and can blank the terminal mid-drag.
        popover?.contentSize = clamped
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
            // Every tab carries its own close button so any session can be
            // dismissed with one click without activating it first.
            tabsStack.addArrangedSubview(makeCloseButton(for: session, at: index))
        }
    }

    private func makeTabButton(for session: TerminalSession, at index: Int, isActive: Bool) -> NSButton {
        let button = TerminalTabButton(title: "", target: self, action: #selector(tabClicked(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.tag = index
        button.attributedTitle = Self.tabTitle(name: session.displayName, status: session.status, isActive: isActive)
        button.lineBreakMode = .byTruncatingTail
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maxTabWidth).isActive = true
        button.toolTip = "\(session.workingDirectory)\nDouble-click or right-click to rename; use the × to close"
        button.setAccessibilityLabel("Terminal \(session.displayName)")
        button.setAccessibilityValue(isActive ? "Active" : "Inactive")
        button.onRightClick = { [weak self] in self?.renameSession(session) }
        button.onDoubleClick = { [weak self] in self?.renameSession(session) }
        return button
    }

    private func renameSession(_ session: TerminalSession) {
        guard let newName = TerminalRenamePrompt.run(currentName: session.name) else { return }
        store.rename(session, to: newName)
    }

    private func makeCloseButton(for session: TerminalSession, at index: Int) -> NSButton {
        let accessibilityLabel = "Close terminal \(session.displayName)"
        let button = Self.makeBarButton(
            symbol: "xmark",
            fallbackTitle: "x",
            accessibilityDescription: accessibilityLabel
        )
        if let image = button.image {
            let configuration = NSImage.SymbolConfiguration(pointSize: Layout.closeSymbolPointSize, weight: .regular)
            button.image = image.withSymbolConfiguration(configuration) ?? image
        }
        button.tag = index
        button.target = self
        button.action = #selector(closeTabClicked(_:))
        button.toolTip = "Close this terminal session"
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    /// The session name only — no status circle. Exited/failed sessions dim so
    /// the state still reads without a leading dot. Truncation and the tab
    /// width cap keep a long title from stretching the strip.
    private static func tabTitle(name: String, status: TerminalSession.Status, isActive: Bool) -> NSAttributedString {
        let nameFont = isActive
            ? NSFont.boldSystemFont(ofSize: Layout.tabFontSize)
            : NSFont.systemFont(ofSize: Layout.tabFontSize)
        let color: NSColor
        switch status {
        case .exited, .failed: color = .tertiaryLabelColor
        case .running, .notStarted: color = .labelColor
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: name, attributes: [
            .font: nameFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
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
        pinButton.setAccessibilityLabel(description)
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

/// Bottom-right drag handle that resizes the popover. Reports the current size
/// when a drag begins and the requested size as the drag proceeds; the
/// controller clamps and applies it.
private final class ResizeGripView: NSView {
    var onResizeBegan: (() -> CGSize)?
    var onResize: ((CGSize) -> Void)?
    var onResizeEnded: (() -> Void)?

    private var startMouse: NSPoint = .zero
    private var startSize: CGSize = .zero

    override func mouseDown(with event: NSEvent) {
        startMouse = event.locationInWindow
        startSize = onResizeBegan?() ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        // Window coordinates increase upward, so dragging the corner down
        // (negative dy) must grow the height.
        onResize?(CGSize(width: startSize.width + dx, height: startSize.height - dy))
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnded?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // Diagonal hatching in the bottom-right corner (y == 0 is the bottom).
        for inset in stride(from: CGFloat(4), through: bounds.width, by: 4) {
            path.move(to: NSPoint(x: bounds.maxX, y: inset))
            path.line(to: NSPoint(x: inset, y: bounds.minY))
        }
        path.stroke()
    }
}

/// Borderless tab button that also reports right-clicks, so a tab can be
/// closed without reaching for its close button.
private final class TerminalTabButton: NSButton {
    var onRightClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func rightMouseUp(with event: NSEvent) {
        guard let onRightClick else {
            super.rightMouseUp(with: event)
            return
        }
        onRightClick()
    }

    override func mouseDown(with event: NSEvent) {
        // A double-click renames; the first click still falls through to the
        // normal action so the tab activates before the rename prompt opens.
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        super.mouseDown(with: event)
    }
}
