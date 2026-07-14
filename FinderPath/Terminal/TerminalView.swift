import AppKit
import CoreText

// CoreText grid renderer and keyboard front end for a TerminalSession.
// Draws styled cells (scrollback above the live grid when scrolled back), a
// block cursor, and an exit/failure banner. Key events route through
// TerminalInputEncoder into the session. PTY-driven redraws are coalesced to
// roughly 60 fps with a dirty flag checked by a main-queue timer that only
// runs while a session is attached and the view is in a window. Mouse
// selection and copy live in TerminalViewSelection.swift.

final class TerminalView: NSView {
    private static let defaultFontSize: CGFloat = 12
    private static let minimumRows = 2
    private static let minimumColumns = 10
    private static let redrawInterval: DispatchTimeInterval = .milliseconds(16)
    private static let faintAlpha: CGFloat = 0.6
    private static let bannerFontSize: CGFloat = 11
    private static let bannerHeight: CGFloat = 18
    private static let bannerTextInset: CGFloat = 6

    // MARK: - Cell metrics

    /// Font-derived geometry, recomputed when fontSize changes. Cell width is
    /// the advance of "M"; one extra point of height keeps descenders and
    /// underlines from clipping against the next row.
    struct CellMetrics {
        let font: NSFont
        let boldFont: NSFont
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let ascent: CGFloat
        /// The font's natural glyph advance before rounding the cell to whole
        /// pixels. The gap between this and cellWidth is applied as per-glyph
        /// kerning so text lands on the same integer grid as the cursor and
        /// backgrounds instead of drifting right across the row.
        let kern: CGFloat

        init(fontSize: CGFloat) {
            font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let probe = CTLineCreateWithAttributedString(
                NSAttributedString(string: "M", attributes: [.font: font])
            )
            var probeAscent: CGFloat = 0
            var probeDescent: CGFloat = 0
            var probeLeading: CGFloat = 0
            let advance = CTLineGetTypographicBounds(probe, &probeAscent, &probeDescent, &probeLeading)
            cellWidth = ceil(CGFloat(advance))
            cellHeight = ceil(probeAscent + probeDescent + probeLeading) + 1
            ascent = probeAscent
            kern = cellWidth - CGFloat(advance)
        }
    }

    // MARK: - State

    var session: TerminalSession? {
        didSet {
            guard session !== oldValue else { return }
            // Only onScreenUpdate belongs to the view; onStatusChange is owned
            // by TerminalPanelController, so the view must never touch it.
            oldValue?.onScreenUpdate = nil
            scrollbackOffset = 0
            clearSelection()
            hookSessionCallbacks()
            updateRedrawTimer()
            pushGridSizeToSession(force: true)
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    var fontSize: CGFloat = TerminalView.defaultFontSize {
        didSet {
            guard fontSize != oldValue else { return }
            metrics = CellMetrics(fontSize: fontSize)
            pushGridSizeToSession(force: true)
            needsDisplay = true
        }
    }

    private(set) var metrics = CellMetrics(fontSize: TerminalView.defaultFontSize)

    /// Lines scrolled up into the scrollback; 0 means the live grid.
    private(set) var scrollbackOffset = 0

    // Selection anchors in content-line space (scrollback lines first, then
    // grid rows); mutated by the mouse handlers in TerminalViewSelection.swift.
    var selectionAnchor: TerminalSelectionPoint?
    var selectionHead: TerminalSelectionPoint?
    var hasActiveSelection = false

    private var screenDirty = false
    private var redrawTimer: DispatchSourceTimer?
    private var scrollAccumulator: CGFloat = 0
    private var lastPushedGrid = (rows: 0, columns: 0)

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Redraw the terminal contents during a live resize instead of letting
        // the layer stretch or drop its cached bitmap — otherwise the text
        // blanks while the window is being resized.
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("FinderPath Terminal")
        setAccessibilityHelp("Interactive terminal. Type commands or select text to copy it.")
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        redrawTimer?.cancel()
    }

    override var wantsUpdateLayer: Bool { false }
    override var isFlipped: Bool { true }

    func focusTerminal() {
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRedrawTimer()
        pushGridSizeToSession()
    }

    private func hookSessionCallbacks() {
        // The view claims only onScreenUpdate. onStatusChange belongs to
        // TerminalPanelController, which repaints the view on status changes;
        // taking it here would clobber the controller's exit/Restart handling.
        session?.onScreenUpdate = { [weak self] in
            self?.screenDirty = true
        }
    }

    /// The coalescing timer runs only while a session is attached and the
    /// view is in a window; it flushes the dirty flag into needsDisplay.
    private func updateRedrawTimer() {
        let shouldRun = session != nil && window != nil
        if shouldRun && redrawTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + Self.redrawInterval, repeating: Self.redrawInterval)
            timer.setEventHandler { [weak self] in
                guard let self, self.screenDirty else { return }
                self.screenDirty = false
                self.needsDisplay = true
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
            timer.resume()
            redrawTimer = timer
        } else if !shouldRun, let timer = redrawTimer {
            timer.cancel()
            redrawTimer = nil
        }
    }

    // MARK: - Sizing

    override func layout() {
        super.layout()
        pushGridSizeToSession()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushGridSizeToSession()
        // The redraw pipeline only reacts to PTY output, so a resize with no new
        // output would otherwise leave the view blank at its new size.
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Reconcile the grid to the final size and force one clean repaint.
        pushGridSizeToSession(force: true)
        needsDisplay = true
    }

    private func gridSize() -> (rows: Int, columns: Int) {
        let rows = max(Int(bounds.height / metrics.cellHeight), Self.minimumRows)
        let columns = max(Int(bounds.width / metrics.cellWidth), Self.minimumColumns)
        return (rows, columns)
    }

    private func pushGridSizeToSession(force: Bool = false) {
        guard let session else { return }
        let size = gridSize()
        guard force || size != lastPushedGrid else { return }
        lastPushedGrid = size
        session.resize(rows: size.rows, columns: size.columns)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        guard let session, let context = NSGraphicsContext.current?.cgContext else { return }
        let screen = session.screen
        let offset = min(scrollbackOffset, screen.scrollbackCount)

        for displayRow in 0..<screen.rows {
            let rowTop = CGFloat(displayRow) * metrics.cellHeight
            guard rowTop < bounds.height else { break }
            let contentLine = screen.scrollbackCount - offset + displayRow
            let rowCells = cells(forContentLine: contentLine, screen: screen)
            drawRowBackgrounds(rowCells, contentLine: contentLine, rowTop: rowTop)
            drawRowText(rowCells, rowTop: rowTop, context: context)
        }

        drawCursorIfNeeded(screen: screen, offset: offset, context: context)
        drawStatusBannerIfNeeded(status: session.status)
    }

    override func accessibilityValue() -> Any? {
        guard let session else { return "" }
        let screen = session.screen
        let offset = min(scrollbackOffset, screen.scrollbackCount)
        return (0..<screen.rows).map { displayRow in
            let contentLine = screen.scrollbackCount - offset + displayRow
            let text = String(cells(forContentLine: contentLine, screen: screen).map(\.character))
            return String(text.reversed().drop(while: { $0 == " " }).reversed())
        }.joined(separator: "\n")
    }

    /// Cells for a content line: scrollback lines are padded or truncated to
    /// the current column count so old, differently sized lines render sanely.
    func cells(forContentLine line: Int, screen: TerminalScreen) -> [TerminalCell] {
        if line < screen.scrollbackCount {
            var lineCells = screen.scrollbackLine(line)
            if lineCells.count < screen.columns {
                lineCells += Array(repeating: .blank, count: screen.columns - lineCells.count)
            } else if lineCells.count > screen.columns {
                lineCells = Array(lineCells.prefix(screen.columns))
            }
            return lineCells
        }
        let row = line - screen.scrollbackCount
        return (0..<screen.columns).map { screen.cell(atRow: row, column: $0) }
    }

    /// Background fills happen before any text so glyph antialiasing blends
    /// against the correct color. Equal-colored runs collapse into one rect.
    private func drawRowBackgrounds(_ rowCells: [TerminalCell], contentLine: Int, rowTop: CGFloat) {
        var column = 0
        while column < rowCells.count {
            guard let fill = backgroundColor(
                for: rowCells[column].style,
                selected: isSelected(contentLine: contentLine, column: column)
            ) else {
                column += 1
                continue
            }
            var runEnd = column + 1
            while runEnd < rowCells.count,
                  backgroundColor(
                      for: rowCells[runEnd].style,
                      selected: isSelected(contentLine: contentLine, column: runEnd)
                  ) == fill {
                runEnd += 1
            }
            fill.setFill()
            NSRect(
                x: CGFloat(column) * metrics.cellWidth,
                y: rowTop,
                width: CGFloat(runEnd - column) * metrics.cellWidth,
                height: metrics.cellHeight
            ).fill()
            column = runEnd
        }
    }

    private func backgroundColor(for style: CellStyle, selected: Bool) -> NSColor? {
        if selected { return .selectedTextBackgroundColor }
        let source = style.inverse ? style.foreground : style.background
        if source == .defaultBackground { return nil }
        return TerminalPalette.color(source)
    }

    private func drawRowText(_ rowCells: [TerminalCell], rowTop: CGFloat, context: CGContext) {
        // Draw each same-style run at its exact grid column so glyph advances
        // can never accumulate drift across a long or multi-color line (e.g. a
        // recalled command or a syntax-highlighted prompt). Kerning keeps
        // glyphs on the grid within a run; the per-run origin resets it between.
        var column = 0
        while column < rowCells.count {
            let style = rowCells[column].style
            let startColumn = column
            var text = String(rowCells[column].character)
            var next = column + 1
            while next < rowCells.count, rowCells[next].style == style {
                text.append(rowCells[next].character)
                next += 1
            }
            let run = NSAttributedString(string: text, attributes: textAttributes(for: style))
            drawLine(run, atX: CGFloat(startColumn) * metrics.cellWidth, rowTop: rowTop, context: context)
            column = next
        }
    }

    /// CTLineDraw in a flipped view needs a mirrored text matrix; the text
    /// position is the baseline measured from the row's top edge.
    private func drawLine(_ attributed: NSAttributedString, atX x: CGFloat, rowTop: CGFloat, context: CGContext) {
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: rowTop + metrics.ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// CoreText ignores AppKit's color/underline attribute keys, so the
    /// CT-prefixed keys carry the resolved style into CTLineDraw.
    private func textAttributes(for style: CellStyle) -> [NSAttributedString.Key: Any] {
        var foreground = TerminalPalette.color(style.inverse ? style.background : style.foreground)
        if style.faint {
            foreground = foreground.withAlphaComponent(Self.faintAlpha)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.bold ? metrics.boldFont : metrics.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor,
            // Pin every glyph to the integer cell grid so text stays aligned
            // with the cursor and backgrounds across the whole row.
            NSAttributedString.Key(kCTKernAttributeName as String): metrics.kern,
        ]
        if style.underline {
            attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] =
                CTUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// Block cursor: the cell inverted (textColor fill, glyph redrawn in the
    /// background color). Hidden while scrolled back or unfocused so stale
    /// cursors never mislead.
    private func drawCursorIfNeeded(screen: TerminalScreen, offset: Int, context: CGContext) {
        guard offset == 0, screen.cursorVisible, window?.firstResponder === self else { return }
        let rect = NSRect(
            x: CGFloat(screen.cursorColumn) * metrics.cellWidth,
            y: CGFloat(screen.cursorRow) * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        NSColor.textColor.setFill()
        rect.fill()

        let cell = screen.cell(atRow: screen.cursorRow, column: screen.cursorColumn)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: cell.style.bold ? metrics.boldFont : metrics.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                NSColor.textBackgroundColor.cgColor,
        ]
        let glyph = NSAttributedString(string: String(cell.character), attributes: attributes)
        drawLine(glyph, atX: rect.minX, rowTop: rect.minY, context: context)
    }

    private func drawStatusBannerIfNeeded(status: TerminalSession.Status) {
        let message: String
        switch status {
        case .exited(let code):
            message = "process exited (code \(code)) - press Restart in the toolbar"
        case .failed(let failure):
            message = failure
        case .notStarted, .running:
            return
        }

        let barRect = NSRect(
            x: 0,
            y: bounds.height - Self.bannerHeight,
            width: bounds.width,
            height: Self.bannerHeight
        )
        NSColor.secondaryLabelColor.setFill()
        barRect.fill()

        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: Self.bannerFontSize),
            .foregroundColor: NSColor.textBackgroundColor,
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(
            x: Self.bannerTextInset,
            y: barRect.minY + (Self.bannerHeight - textSize.height) / 2
        ))
    }

    // MARK: - Scrollback

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY / metrics.cellHeight
        } else {
            scrollAccumulator += event.scrollingDeltaY
        }
        let wholeLines = Int(scrollAccumulator.rounded(.towardZero))
        guard wholeLines != 0 else { return }
        scrollAccumulator -= CGFloat(wholeLines)

        let limit = session.screen.scrollbackCount
        let updated = min(max(scrollbackOffset + wholeLines, 0), limit)
        if updated != scrollbackOffset {
            scrollbackOffset = updated
            needsDisplay = true
        }
    }

    private func snapToLiveGrid() {
        guard scrollbackOffset != 0 else { return }
        scrollbackOffset = 0
        needsDisplay = true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true // cursor is drawn only while focused
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard let session else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copySelection()
            case "v":
                snapToLiveGrid()
                pasteFromGeneralPasteboard()
            default:
                super.keyDown(with: event)
            }
            return
        }

        // Typing while scrolled back always snaps to the live grid.
        snapToLiveGrid()

        let optionAsMeta = FinderPathPreferences.terminalOptionAsMeta
        let terminalModifiers = Self.terminalModifiers(from: modifiers, optionAsMeta: optionAsMeta)
        if let special = Self.specialKey(forKeyCode: event.keyCode) {
            session.send(special: special, modifiers: terminalModifiers)
            return
        }

        if modifiers.contains(.control),
           let character = event.charactersIgnoringModifiers?.first,
           let bytes = TerminalInputEncoder.encodeControl(
               character: character,
               meta: optionAsMeta && modifiers.contains(.option)
           ) {
            session.send(bytes: bytes)
            return
        }

        let usesMeta = optionAsMeta && modifiers.contains(.option)
        let text = usesMeta ? event.charactersIgnoringModifiers : event.characters
        if let text, !text.isEmpty, Self.isPrintable(text) {
            session.send(text: text, meta: usesMeta)
            return
        }

        super.keyDown(with: event)
    }

    private func pasteFromGeneralPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        session?.paste(text)
    }

    /// HIToolbox kVK_* virtual key codes for the non-character keys.
    private static func specialKey(forKeyCode keyCode: UInt16) -> TerminalInputEncoder.SpecialKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .forwardDelete
        case 53: return .escape
        case 48: return .tab
        case 36, 76: return .enter // return and keypad enter
        case 51: return .backspace
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        case 101: return .function(9)
        case 109: return .function(10)
        case 103: return .function(11)
        case 111: return .function(12)
        default: return nil
        }
    }

    private static func terminalModifiers(
        from flags: NSEvent.ModifierFlags,
        optionAsMeta: Bool
    ) -> TerminalInputEncoder.Modifiers {
        var result: TerminalInputEncoder.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if optionAsMeta, flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    /// NSEvent encodes non-character keys in the Unicode private-use range
    /// 0xF700-0xF8FF; those must never reach the shell as text.
    private static func isPrintable(_ characters: String) -> Bool {
        !characters.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
    }
}

// MARK: - Color palette

/// Maps TerminalColor to concrete NSColors: system dynamic colors for the
/// defaults (so light and dark mode both work), the standard xterm table for
/// ANSI 0-15, the 6x6x6 cube plus grayscale ramp for 16-255, and sRGB for
/// truecolor.
private enum TerminalPalette {
    static func color(_ terminalColor: TerminalColor) -> NSColor {
        switch terminalColor {
        case .defaultForeground:
            return .textColor
        case .defaultBackground:
            return .textBackgroundColor
        case .ansi(let index):
            return ansiTable[Int(min(index, 15))]
        case .palette(let index):
            return extendedColor(index)
        case .rgb(let red, let green, let blue):
            return srgb(Int(red), Int(green), Int(blue))
        }
    }

    private static func extendedColor(_ index: UInt8) -> NSColor {
        if index < 16 {
            return ansiTable[Int(index)]
        }
        if index >= 232 {
            let level = 8 + 10 * (Int(index) - 232)
            return srgb(level, level, level)
        }
        let cubeIndex = Int(index) - 16
        return srgb(
            cubeSteps[cubeIndex / 36],
            cubeSteps[(cubeIndex / 6) % 6],
            cubeSteps[cubeIndex % 6]
        )
    }

    /// xterm's color cube component values for levels 0-5.
    private static let cubeSteps = [0, 95, 135, 175, 215, 255]

    /// Standard xterm colors 0-7 and bright variants 8-15.
    private static let ansiTable: [NSColor] = [
        srgb(0, 0, 0), srgb(205, 0, 0), srgb(0, 205, 0), srgb(205, 205, 0),
        srgb(0, 0, 238), srgb(205, 0, 205), srgb(0, 205, 205), srgb(229, 229, 229),
        srgb(127, 127, 127), srgb(255, 0, 0), srgb(0, 255, 0), srgb(255, 255, 0),
        srgb(92, 92, 255), srgb(255, 0, 255), srgb(0, 255, 255), srgb(255, 255, 255),
    ]

    private static func srgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
