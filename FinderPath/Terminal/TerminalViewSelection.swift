import AppKit

// Mouse-driven text selection and clipboard copy for TerminalView. Kept in a
// companion file so the renderer stays focused on drawing.

/// A selection endpoint: an *absolute* line (see `TerminalScreen.scrollbackBase`)
/// and a column within it.
///
/// Content-line indices shift down every time the scrollback ring trims, so a
/// selection stored in that space slides onto different text as output arrives —
/// the highlight and Cmd+C end up on a line the user never selected. Absolute
/// line numbers stay attached to their text for its whole life, and a line that
/// falls out of the ring resolves to nil rather than to a stranger.
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
        guard hasActiveSelection, let anchor = selectionAnchor, let head = selectionHead,
              let session else { return false }
        let start = min(anchor, head)
        let end = max(anchor, head)
        // The renderer walks content lines; the selection lives in absolute
        // space, so lift the row being drawn rather than lowering the anchors.
        let line = session.screen.absoluteLine(forContentLine: contentLine)

        guard line >= start.line, line <= end.line else { return false }
        if start.line == end.line {
            return column >= start.column && column <= end.column
        }
        if line == start.line { return column >= start.column }
        if line == end.line { return column <= end.column }
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

        var rows: [TerminalTextJoiner.Row] = []
        for absoluteLine in start.line...end.line {
            // A line trimmed out of the ring while the selection was held is
            // genuinely gone; skip it rather than substituting whatever text
            // now sits at its old index.
            guard let line = screen.contentLine(forAbsoluteLine: absoluteLine) else { continue }
            let cells = cells(forContentLine: line, screen: screen)
            // A row the terminal wrapped continues on the next one, so it must
            // not gain a newline: a path that merely overflowed the window has
            // to come back as one pasteable line.
            let continues = screen.isLineWrapped(contentLine: line)
            let firstColumn = absoluteLine == start.line ? start.column : 0
            let lastColumn = absoluteLine == end.line ? end.column : cells.count - 1
            guard firstColumn <= lastColumn, firstColumn < cells.count else {
                rows.append(TerminalTextJoiner.Row(text: "", continuesToNextRow: continues))
                continue
            }
            let upperBound = min(lastColumn, cells.count - 1)
            // Trailing blanks are row padding, not content -- but a wrapped row
            // runs to the edge, so trimming it would eat real characters.
            let text = TerminalRowText.string(
                from: cells[firstColumn...upperBound],
                trimmingTrailingSpaces: !continues
            )
            rows.append(TerminalTextJoiner.Row(text: text, continuesToNextRow: continues))
        }

        let joined = TerminalTextJoiner.join(rows)
        guard !joined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    /// Maps a mouse event to an absolute-line/column endpoint, clamped to the
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

        return TerminalSelectionPoint(
            line: screen.absoluteLine(forContentLine: contentLine),
            column: clampedColumn
        )
    }
}
