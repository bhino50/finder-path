import Foundation

// The terminal's grid model: a rows x columns matrix of styled cells plus
// cursor state, DECSTBM scroll region, an alternate screen buffer, and a
// scrollback ring. Applies parsed TerminalActions; pure logic, no AppKit.

struct TerminalScreen {
    private(set) var rows: Int
    private(set) var columns: Int
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var cursorVisible = true
    private(set) var usingAlternateScreen = false
    private(set) var bracketedPaste = false
    private(set) var applicationCursorKeys = false
    private(set) var autowrap = true
    private(set) var title = ""

    private var grid: [[TerminalCell]]
    private var savedPrimary: (grid: [[TerminalCell]], cursorRow: Int, cursorColumn: Int)?
    private var scrollback: [[TerminalCell]] = []
    private let scrollbackLimit: Int

    /// 0-based inclusive scroll region bounds.
    private var regionTop = 0
    private var regionBottom: Int

    /// Current SGR brush applied to prints and erases.
    private var brush = CellStyle.plain
    private var savedCursor: (row: Int, column: Int)?

    /// Deferred autowrap: printing in the last column parks the cursor there
    /// until the next print, which wraps first (matches xterm).
    private var pendingWrap = false

    var scrollbackCount: Int { scrollback.count }

    init(rows: Int, columns: Int, scrollbackLimit: Int = 2000) {
        self.rows = max(rows, 1)
        self.columns = max(columns, 1)
        self.scrollbackLimit = max(scrollbackLimit, 0)
        self.regionBottom = self.rows - 1
        self.grid = Self.blankGrid(rows: self.rows, columns: self.columns)
    }

    private static func blankGrid(rows: Int, columns: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
    }

    private var blankCell: TerminalCell { .blank(withBackgroundOf: brush) }

    // MARK: - Reading

    func cell(atRow row: Int, column: Int) -> TerminalCell {
        guard row >= 0, row < rows, column >= 0, column < columns else { return .blank }
        return grid[row][column]
    }

    func scrollbackLine(_ index: Int) -> [TerminalCell] {
        guard index >= 0, index < scrollback.count else { return [] }
        return scrollback[index]
    }

    func lineText(_ row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return String(grid[row].prefix(columns).map(\.character))
    }

    // MARK: - Applying actions

    mutating func apply(_ action: TerminalAction) {
        switch action {
        case .hardReset:
            hardReset()
        case .print(let character):
            printCharacter(character)
        case .lineFeed:
            lineFeed()
        case .carriageReturn:
            cursorColumn = 0
            pendingWrap = false
        case .backspace:
            cursorColumn = max(cursorColumn - 1, 0)
            pendingWrap = false
        case .tab:
            let nextStop = min(((cursorColumn / 8) + 1) * 8, columns - 1)
            cursorColumn = nextStop
            pendingWrap = false
        case .bell:
            break
        case .moveCursor(let row, let column):
            if let row { cursorRow = clampRow(row - 1) }
            if let column { cursorColumn = clampColumn(column - 1) }
            pendingWrap = false
        case .moveCursorRelative(let deltaRows, let deltaColumns):
            cursorRow = clampRow(cursorRow + deltaRows)
            cursorColumn = clampColumn(cursorColumn + deltaColumns)
            pendingWrap = false
        case .setStyle(let style):
            brush = style
        case .eraseInDisplay(let mode):
            eraseInDisplay(mode)
        case .eraseInLine(let mode):
            eraseInLine(mode)
        case .insertLines(let amount):
            insertLines(amount)
        case .deleteLines(let amount):
            deleteLines(amount)
        case .insertCharacters(let amount):
            insertCharacters(amount)
        case .deleteCharacters(let amount):
            deleteCharacters(amount)
        case .eraseCharacters(let amount):
            discardHiddenColumns(in: cursorRow)
            let end = min(cursorColumn + max(amount, 1), columns)
            for column in cursorColumn..<end { grid[cursorRow][column] = blankCell }
        case .setScrollRegion(let top, let bottom):
            let resolvedBottom = (bottom <= 0 || bottom > rows) ? rows : bottom
            let newTop = clampRow(top - 1)
            let newBottom = clampRow(resolvedBottom - 1)
            if newTop < newBottom {
                regionTop = newTop
                regionBottom = newBottom
            } else {
                regionTop = 0
                regionBottom = rows - 1
            }
            cursorRow = 0
            cursorColumn = 0
            pendingWrap = false
        case .scrollUp(let amount):
            // Clamp to region height so a huge CSI parameter cannot force
            // disproportionate work from a few bytes of hostile output.
            for _ in 0..<min(max(amount, 1), regionBottom - regionTop + 1) {
                scrollRegionUp(recordScrollback: false)
            }
        case .scrollDown(let amount):
            for _ in 0..<min(max(amount, 1), regionBottom - regionTop + 1) {
                scrollRegionDown()
            }
        case .saveCursor:
            savedCursor = (cursorRow, cursorColumn)
        case .restoreCursor:
            if let saved = savedCursor {
                cursorRow = clampRow(saved.row)
                cursorColumn = clampColumn(saved.column)
            }
            pendingWrap = false
        case .setMode(let mode, let enabled):
            setMode(mode, enabled)
        case .setTitle(let newTitle):
            title = newTitle
        case .reverseIndex:
            if cursorRow == regionTop {
                scrollRegionDown()
            } else {
                cursorRow = clampRow(cursorRow - 1)
            }
            pendingWrap = false
        case .index:
            lineFeed()
        case .nextLine:
            cursorColumn = 0
            lineFeed()
        case .reportDeviceStatus:
            break // replies are the session's responsibility
        }
    }

    /// Restore the terminal's initial state without retaining hidden cursor,
    /// alternate-screen, style, title, or private-mode state from before RIS.
    private mutating func hardReset() {
        grid = Self.blankGrid(rows: rows, columns: columns)
        savedPrimary = nil
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        usingAlternateScreen = false
        bracketedPaste = false
        applicationCursorKeys = false
        autowrap = true
        title = ""
        regionTop = 0
        regionBottom = rows - 1
        brush = .plain
        savedCursor = nil
        pendingWrap = false
    }

    // MARK: - Printing and scrolling

    private mutating func printCharacter(_ character: Character) {
        if pendingWrap && autowrap {
            cursorColumn = 0
            lineFeed()
        }
        discardHiddenColumns(in: cursorRow)
        grid[cursorRow][cursorColumn] = TerminalCell(character: character, style: brush)
        if cursorColumn == columns - 1 {
            pendingWrap = autowrap
        } else {
            cursorColumn += 1
        }
    }

    private mutating func lineFeed() {
        pendingWrap = false
        if cursorRow == regionBottom {
            scrollRegionUp(recordScrollback: true)
        } else {
            cursorRow = clampRow(cursorRow + 1)
        }
    }

    private mutating func scrollRegionUp(recordScrollback: Bool) {
        // Only a full-screen region on the primary screen feeds scrollback.
        let feedsScrollback = recordScrollback
            && !usingAlternateScreen
            && regionTop == 0
            && regionBottom == rows - 1
            && scrollbackLimit > 0

        if feedsScrollback {
            scrollback.append(grid[regionTop])
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst(scrollback.count - scrollbackLimit)
            }
        }

        for row in regionTop..<regionBottom {
            grid[row] = grid[row + 1]
        }
        grid[regionBottom] = Array(repeating: blankCell, count: columns)
    }

    private mutating func scrollRegionDown() {
        var row = regionBottom
        while row > regionTop {
            grid[row] = grid[row - 1]
            row -= 1
        }
        grid[regionTop] = Array(repeating: blankCell, count: columns)
    }

    // MARK: - Erase

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    grid[row] = Array(repeating: blankCell, count: columns)
                }
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow {
                grid[row] = Array(repeating: blankCell, count: columns)
            }
        case 2, 3:
            grid = Array(repeating: Array(repeating: blankCell, count: columns), count: rows)
        default:
            break
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        discardHiddenColumns(in: cursorRow)
        switch mode {
        case 0:
            for column in cursorColumn..<columns { grid[cursorRow][column] = blankCell }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { grid[cursorRow][column] = blankCell }
        case 2:
            grid[cursorRow] = Array(repeating: blankCell, count: columns)
        default:
            break
        }
    }

    // MARK: - Insert and delete

    private mutating func insertLines(_ amount: Int) {
        guard cursorRow >= regionTop, cursorRow <= regionBottom else { return }
        // Inserting more lines than fit below the cursor is indistinguishable
        // from filling the region, so cap the work at the region size.
        for _ in 0..<min(max(amount, 1), regionBottom - cursorRow + 1) {
            var row = regionBottom
            while row > cursorRow {
                grid[row] = grid[row - 1]
                row -= 1
            }
            grid[cursorRow] = Array(repeating: blankCell, count: columns)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private mutating func deleteLines(_ amount: Int) {
        guard cursorRow >= regionTop, cursorRow <= regionBottom else { return }
        for _ in 0..<min(max(amount, 1), regionBottom - cursorRow + 1) {
            for row in cursorRow..<regionBottom {
                grid[row] = grid[row + 1]
            }
            grid[regionBottom] = Array(repeating: blankCell, count: columns)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private mutating func insertCharacters(_ amount: Int) {
        discardHiddenColumns(in: cursorRow)
        let count = min(max(amount, 1), columns - cursorColumn)
        var line = grid[cursorRow]
        line.removeLast(count)
        line.insert(contentsOf: Array(repeating: blankCell, count: count), at: cursorColumn)
        grid[cursorRow] = line
    }

    private mutating func deleteCharacters(_ amount: Int) {
        discardHiddenColumns(in: cursorRow)
        let count = min(max(amount, 1), columns - cursorColumn)
        var line = grid[cursorRow]
        line.removeSubrange(cursorColumn..<(cursorColumn + count))
        line.append(contentsOf: Array(repeating: blankCell, count: count))
        grid[cursorRow] = line
    }

    // MARK: - Modes

    private mutating func setMode(_ mode: TerminalMode, _ enabled: Bool) {
        switch mode {
        case .alternateScreen:
            guard enabled != usingAlternateScreen else { return }
            if enabled {
                savedPrimary = (grid, cursorRow, cursorColumn)
                grid = Array(repeating: Array(repeating: blankCell, count: columns), count: rows)
                cursorRow = 0
                cursorColumn = 0
                usingAlternateScreen = true
            } else {
                if let saved = savedPrimary {
                    grid = saved.grid
                    cursorRow = clampRow(saved.cursorRow)
                    cursorColumn = clampColumn(saved.cursorColumn)
                }
                savedPrimary = nil
                usingAlternateScreen = false
            }
            regionTop = 0
            regionBottom = rows - 1
            pendingWrap = false
        case .autowrap:
            autowrap = enabled
        case .bracketedPaste:
            bracketedPaste = enabled
        case .cursorVisible:
            cursorVisible = enabled
        case .applicationCursorKeys:
            applicationCursorKeys = enabled
        }
    }

    // MARK: - Resize

    mutating func resize(rows newRows: Int, columns newColumns: Int) {
        let targetRows = max(newRows, 1)
        let targetColumns = max(newColumns, 1)
        guard targetRows != rows || targetColumns != columns else { return }

        // Rows dropped off the top when shrinking are preserved in scrollback
        // (primary screen only) so resizing smaller never loses text outright.
        let droppedRows = max(grid.count - targetRows, 0)
        if droppedRows > 0, !usingAlternateScreen, scrollbackLimit > 0 {
            for row in 0..<droppedRows {
                scrollback.append(grid[row])
            }
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst(scrollback.count - scrollbackLimit)
            }
        }

        if usingAlternateScreen {
            // A full-screen (alternate-screen) app owns its buffer and repaints
            // it on the SIGWINCH that follows a resize. Reflowing the old,
            // absolutely-positioned frame into the new width leaves mangled
            // overlap the app's redraw may not fully clear (e.g. a resized
            // Claude Code / vim frame), so hand it a clean slate instead.
            grid = Self.blankGrid(rows: targetRows, columns: targetColumns)
        } else {
            grid = Self.resizeGrid(grid, rows: targetRows, columns: targetColumns)
        }
        if let saved = savedPrimary {
            savedPrimary = (
                Self.resizeGrid(saved.grid, rows: targetRows, columns: targetColumns),
                min(saved.cursorRow, targetRows - 1),
                min(saved.cursorColumn, targetColumns - 1)
            )
        }

        // The grid dropped `droppedTop` rows off the top when shrinking, so
        // move the cursor up by the same amount to keep it on its own line.
        let droppedTop = max(rows - targetRows, 0)
        rows = targetRows
        columns = targetColumns
        regionTop = 0
        regionBottom = rows - 1
        cursorRow = clampRow(cursorRow - droppedTop)
        cursorColumn = clampColumn(cursorColumn)
        pendingWrap = false
    }

    private static func resizeGrid(_ source: [[TerminalCell]], rows: Int, columns: Int) -> [[TerminalCell]] {
        // Shrinking keeps the BOTTOM rows: the cursor and most recent output
        // live there, so dropping the top preserves what the user is looking
        // at instead of discarding the active prompt line.
        var result = source.suffix(rows).map { line -> [TerminalCell] in
            // Keep cells beyond the temporarily visible width. If the user
            // widens the terminal again before that row is overwritten, its
            // right-hand content reappears instead of being destroyed.
            guard line.count < columns else { return line }
            return line + Array(repeating: TerminalCell.blank, count: columns - line.count)
        }
        while result.count < rows {
            result.append(Array(repeating: TerminalCell.blank, count: columns))
        }
        return result
    }

    /// A row can retain hidden right-hand cells across a temporary narrowing.
    /// Once output mutates that row at the new width, discard the stale overflow
    /// so it cannot reappear after newer content has replaced the line.
    private mutating func discardHiddenColumns(in row: Int) {
        guard row >= 0, row < grid.count, grid[row].count > columns else { return }
        grid[row] = Array(grid[row].prefix(columns))
    }

    // MARK: - Clamping

    private func clampRow(_ row: Int) -> Int { min(max(row, 0), rows - 1) }
    private func clampColumn(_ column: Int) -> Int { min(max(column, 0), columns - 1) }
}
