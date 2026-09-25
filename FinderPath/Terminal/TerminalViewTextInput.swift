import AppKit
import CoreText

// Input-method support for TerminalView. Dead keys, CJK composition, the
// emoji picker, and dictation all arrive through NSTextInputClient; only
// committed text reaches the shell. Composing (marked) text is an overlay at
// the cursor, so a cancelled composition never touches the screen model.
// Key routing and doCommand(by:) live with keyDown in TerminalView.swift.

extension TerminalView: NSTextInputClient {
    private static let markedTextCaretWidth: CGFloat = 1

    func insertText(_ string: Any, replacementRange: NSRange) {
        if markedText.isActive {
            markedText.discard()
            needsDisplay = true
        }
        sendCommittedText(Self.plainText(from: string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText.mark(Self.plainText(from: string), selectedRange: selectedRange)
        // A composition is typed at the live cursor, not into scrollback.
        if markedText.isActive {
            snapToLiveGrid()
        }
        needsDisplay = true
    }

    /// Accepts the composition as typed, as NSTextView does.
    func unmarkText() {
        guard markedText.isActive else { return }
        let accepted = markedText.unmark()
        needsDisplay = true
        sendCommittedText(accepted)
    }

    func selectedRange() -> NSRange {
        markedText.selectedRange
    }

    func markedRange() -> NSRange {
        markedText.markedRange
    }

    func hasMarkedText() -> Bool {
        markedText.isActive
    }

    /// The shell owns the line being edited, so there is no document text to
    /// offer for reconversion.
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Candidate windows and the emoji picker anchor to the cursor cell, in
    /// screen coordinates.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let session, let window else { return .zero }
        let cursorInWindow = convert(cursorCellRect(screen: session.screen), to: nil)
        return window.convertToScreen(cursorInWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// The terminal can sit in a floating panel or a status-item popover;
    /// reporting that level keeps candidate windows above it.
    func windowLevel() -> Int {
        (window?.level ?? .normal).rawValue
    }

    // MARK: - Composition lifecycle

    /// Drops a composition without sending it, because the session it was
    /// typed for has been replaced or reset. The input method forgets it too.
    func discardMarkedText() {
        guard markedText.isActive else { return }
        markedText.discard()
        inputContext?.discardMarkedText()
        needsDisplay = true
    }

    /// Committed text follows the typed-character path: back to the live
    /// grid, then to the shell. Private-use function-key characters are
    /// never typed as text.
    private func sendCommittedText(_ text: String) {
        guard !text.isEmpty, TerminalInputEncoder.isPrintable(text) else { return }
        snapToLiveGrid()
        session?.send(text: text)
    }

    private static func plainText(from string: Any) -> String {
        if let attributed = string as? NSAttributedString {
            return attributed.string
        }
        return string as? String ?? ""
    }

    // MARK: - Drawing

    /// Underlined at the cursor over a plain background, as AppKit renders
    /// compositions, with a caret at the input method's selection. Wide
    /// characters take two cells so the overlay lines up with the grid.
    func drawMarkedTextIfNeeded(screen: TerminalScreen, offset: Int, context: CGContext) {
        guard markedText.isActive, offset == 0, window?.firstResponder === self else { return }
        let cursorCell = cursorCellRect(screen: screen)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.textColor.cgColor,
            NSAttributedString.Key(kCTUnderlineStyleAttributeName as String): CTUnderlineStyle.single.rawValue,
        ]
        let caretOffset = markedText.selectedRange.location
        var x = cursorCell.minX
        var caretX = x
        var utf16Offset = 0
        for character in markedText.text {
            let width = CGFloat(max(TerminalScreen.columnWidth(of: character), 1)) * metrics.cellWidth
            NSColor.textBackgroundColor.setFill()
            NSRect(x: x, y: cursorCell.minY, width: width, height: cursorCell.height).fill()
            let glyph = NSAttributedString(string: String(character), attributes: attributes)
            drawLine(glyph, atX: x, rowTop: cursorCell.minY, context: context)
            x += width
            utf16Offset += character.utf16.count
            if utf16Offset <= caretOffset {
                caretX = x
            }
        }
        NSColor.textColor.setFill()
        NSRect(
            x: caretX,
            y: cursorCell.minY,
            width: Self.markedTextCaretWidth,
            height: cursorCell.height
        ).fill()
    }
}
