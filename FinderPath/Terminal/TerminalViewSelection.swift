import AppKit

// Mouse-driven text selection and clipboard copy for TerminalView. Kept in a
// companion file so the renderer stays focused on drawing. Selection is
// expressed in content-line space (scrollback lines first, then live grid
// rows) so it stays anchored to text while the user scrolls.

/// A selection endpoint: a content line and a column within it.
struct TerminalSelectionPoint: Equatable, Comparable {
    var line: Int
    var column: Int

    static func < (lhs: TerminalSelectionPoint, rhs: TerminalSelectionPoint) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.column < rhs.column
    }
}

extension TerminalView {
    /// Whether a cell participates in the current selection. Line-major:
    /// interior lines are fully covered, the first and last lines are bounded
    /// by their respective columns.
    func isSelected(contentLine: Int, column: Int) -> Bool {
        guard hasActiveSelection, let anchor = selectionAnchor, let head = selectionHead else { return false }
        let start = min(anchor, head)
        let end = max(anchor, head)

        guard contentLine >= start.line, contentLine <= end.line else { return false }
        if start.line == end.line {
            return column >= start.column && column <= end.column
        }
        if contentLine == start.line { return column >= start.column }
        if contentLine == end.line { return column <= end.column }
        return true
    }

    func clearSelection() {
        guard hasActiveSelection || selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        hasActiveSelection = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = selectionPoint(for: event) else {
            clearSelection()
            return
        }
        selectionAnchor = point
        selectionHead = point
        hasActiveSelection = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionAnchor != nil, let point = selectionPoint(for: event) else { return }
        selectionHead = point
        hasActiveSelection = selectionHead != selectionAnchor
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // A click with no drag is just a focus tap; drop the empty selection.
        if !hasActiveSelection {
            clearSelection()
        }
    }

    func copySelection() {
        guard hasActiveSelection, let anchor = selectionAnchor, let head = selectionHead,
              let session else { return }
        let start = min(anchor, head)
        let end = max(anchor, head)
        let screen = session.screen

        var lines: [String] = []
        for line in start.line...end.line {
            let cells = cells(forContentLine: line, screen: screen)
            let firstColumn = line == start.line ? start.column : 0
            let lastColumn = line == end.line ? end.column : cells.count - 1
            guard firstColumn <= lastColumn, firstColumn < cells.count else {
                lines.append("")
                continue
            }
            let upperBound = min(lastColumn, cells.count - 1)
            let text = String(cells[firstColumn...upperBound].map(\.character))
            // Trailing blanks on a terminal row are padding, not content.
            lines.append(String(text.reversed().drop(while: { $0 == " " }).reversed()))
        }

        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    /// Maps a mouse event to a content-line/column endpoint, clamped to the
    /// current screen so drags past the edges stay in bounds.
    private func selectionPoint(for event: NSEvent) -> TerminalSelectionPoint? {
        guard let session else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let screen = session.screen
        let offset = min(scrollbackOffset, screen.scrollbackCount)

        let displayRow = Int((local.y / metrics.cellHeight).rounded(.down))
        let clampedRow = min(max(displayRow, 0), screen.rows - 1)
        let contentLine = screen.scrollbackCount - offset + clampedRow

        let column = Int((local.x / metrics.cellWidth).rounded(.down))
        let clampedColumn = min(max(column, 0), screen.columns - 1)

        return TerminalSelectionPoint(line: contentLine, column: clampedColumn)
    }
}
