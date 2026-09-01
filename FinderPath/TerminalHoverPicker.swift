import AppKit

/// Transient popover that appears when the pointer dwells on the status item,
/// listing the open terminal sessions so one click jumps straight into a
/// terminal without opening the full status menu.
///
/// Callers own the hover detection (the status button's tracking area) and the
/// suppression rules (HoverPickerLogic); this type owns presentation, row
/// actions, and dismissal. While shown, a proximity timer closes the popover
/// once the pointer has left both the status button and the popover — a
/// transient NSPopover only closes on clicks elsewhere, which would leave a
/// hover-summoned popover stranded on screen.
@MainActor
final class TerminalHoverPickerController {
    var onOpenSession: ((TerminalSession) -> Void)?
    var onCloseSession: ((TerminalSession) -> Void)?

    private let store: TerminalSessionStore
    private var popover: NSPopover?
    private var proximityTimer: Timer?
    private var escapeMonitor: Any?
    private var missedProximityChecks = 0
    private weak var anchorButton: NSStatusBarButton?

    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 280
    private static let verticalPadding: CGFloat = 8
    private static let proximityInterval: TimeInterval = 0.25
    private static let escapeKeyCode: UInt16 = 53
    // Two consecutive misses (~0.5s) tolerate the gap the pointer crosses
    // between the menu bar and the popover without flickering it away.
    private static let allowedMissedChecks = 2

    init(store: TerminalSessionStore) {
        self.store = store
    }

    var isShown: Bool {
        popover?.isShown == true
    }

    func present(relativeTo statusButton: NSStatusBarButton) {
        guard !isShown else { return }
        let sessions = store.sessions
        guard !sessions.isEmpty else { return }

        anchorButton = statusButton
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = makeContentController(sessions: sessions)
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        self.popover = popover
        startProximityTimer()
        startEscapeMonitor()
    }

    func dismiss() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        missedProximityChecks = 0
        stopEscapeMonitor()
        popover?.performClose(nil)
        popover = nil
    }

    /// Escape closes the picker, matching every other transient macOS popover.
    /// A local monitor only sees events while FinderPath is active, which is
    /// the case whenever the popover has taken focus; the proximity timer stays
    /// the fallback for a hover that never activated the app. A global monitor
    /// would cover that too, but only by asking for Accessibility access, which
    /// is far too much to request for one dismissal shortcut.
    private func startEscapeMonitor() {
        stopEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            self?.dismiss()
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }

    private func makeContentController(sessions: [TerminalSession]) -> NSViewController {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        // Without this the popover is an unlabelled container to VoiceOver;
        // the rows inside it carry their own labels from TerminalMenuRowView.
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("Open terminals")
        stack.edgeInsets = NSEdgeInsets(
            top: Self.verticalPadding, left: 0, bottom: Self.verticalPadding, right: 0
        )

        for session in sessions {
            let row = TerminalMenuRowView(name: session.displayName)
            row.toolTip = session.workingDirectory
            row.onOpen = { [weak self] in
                self?.dismiss()
                self?.onOpenSession?(session)
            }
            row.onClose = { [weak self] in
                self?.onCloseSession?(session)
                self?.refreshAfterClose()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: Self.width),
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            ])
        }

        let controller = NSViewController()
        controller.view = stack
        let height = CGFloat(sessions.count) * Self.rowHeight + Self.verticalPadding * 2
        stack.setFrameSize(NSSize(width: Self.width, height: height))
        return controller
    }

    /// Closing a session from a row leaves the popover open so several can be
    /// cleaned up in a row; the list rebuilds, and the last close dismisses.
    private func refreshAfterClose() {
        guard let popover, popover.isShown else { return }
        let sessions = store.sessions
        guard !sessions.isEmpty else {
            dismiss()
            return
        }
        popover.contentViewController = makeContentController(sessions: sessions)
    }

    private func startProximityTimer() {
        // A second start while a timer is live must replace it, not stack a
        // permanent 4 Hz wakeup that nothing can invalidate.
        proximityTimer?.invalidate()
        missedProximityChecks = 0
        let timer = Timer(timeInterval: Self.proximityInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkProximity()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func checkProximity() {
        guard let popover, popover.isShown else {
            dismiss()
            return
        }
        if pointerIsNearPicker() {
            missedProximityChecks = 0
            return
        }
        missedProximityChecks += 1
        if missedProximityChecks > Self.allowedMissedChecks {
            dismiss()
        }
    }

    private func pointerIsNearPicker() -> Bool {
        let location = NSEvent.mouseLocation
        var region: NSRect?

        if let button = anchorButton, let buttonWindow = button.window {
            region = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
        }

        if let popoverWindow = popover?.contentViewController?.view.window {
            let frame = popoverWindow.frame
            region = region.map { $0.union(frame) } ?? frame
        }

        // The union spans the gap between the menu bar and the popover beak,
        // so a pointer crossing it slowly is still counted as near.
        guard let region else { return false }
        return region.insetBy(dx: -8, dy: -8).contains(location)
    }
}
