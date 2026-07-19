import AppKit

@MainActor
enum WindowPresentation {
    static func present(_ controller: NSWindowController) {
        guard let window = controller.window else { return }

        if let visibleFrame = activeScreen()?.visibleFrame {
            let origin = NSPoint(
                x: min(
                    max(visibleFrame.midX - window.frame.width / 2, visibleFrame.minX),
                    visibleFrame.maxX - window.frame.width
                ),
                y: min(
                    max(visibleFrame.midY - window.frame.height / 2, visibleFrame.minY),
                    visibleFrame.maxY - window.frame.height
                )
            )
            window.setFrameOrigin(origin)
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
