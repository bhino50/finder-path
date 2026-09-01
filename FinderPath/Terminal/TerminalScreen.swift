import Foundation

// The terminal's grid model: a rows x columns matrix of styled cells plus
// cursor state, DECSTBM scroll region, an alternate screen buffer, and a
// scrollback ring. Applies parsed TerminalActions; pure logic, no AppKit.

struct TerminalScreen {
    /// Complex graphemes are useful, but an endless combining-mark stream can
    /// otherwise grow one terminal cell forever. Real-world emoji sequences
    /// are comfortably below this defensive ceiling.
    static let maximumScalarsPerCell = 64
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

    private var grid: [TerminalLine]
    /// The primary screen's contents parked while the alternate screen is up.
    /// `savedCursor` travels with it: DECSC/DECRC state is per screen, so a TUI
    /// issuing ESC 7 must not clobber the position the shell saved earlier.
    private var savedPrimary: (
        grid: [TerminalLine],
        cursorRow: Int,
        cursorColumn: Int,
        savedCursor: (row: Int, column: Int)?
    )?
    private var scrollback: [TerminalLine] = []
    /// Logical front of `scrollback`. Advancing this index makes steady-state
    /// trimming O(1); the backing array is compacted only occasionally so total
    /// work remains amortized linear under sustained output.
    private var scrollbackHead = 0
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

    var scrollbackCount: Int { scrollback.count - scrollbackHead }

    /// How many lines have been discarded off the front of the scrollback ring.
    ///
    /// Content-line indices (scrollback lines first, then live grid rows) are
    /// relative to the front of the ring, so every trim shifts them down by one.
    /// Anything that has to stay pinned to *text* while output keeps arriving —
    /// a held selection, a scrolled-back viewport — must store the absolute line
    /// number instead and convert back through `contentLine(forAbsoluteLine:)`,
    /// or it silently slides onto whatever text later occupies that index.
    private(set) var scrollbackBase = 0

    /// The stable identity of a content line: unchanged for the life of the text
    /// it names, however much the ring trims afterwards.
    func absoluteLine(forContentLine line: Int) -> Int {
        scrollbackBase + line
    }

    /// Where `absolute` currently sits, or nil once it has been trimmed away or
    /// if it names a line past the live grid. Returning nil rather than a
    /// clamped index is deliberate: silently resolving an evicted line to its
    /// old index is exactly the drift this exists to prevent.
    func contentLine(forAbsoluteLine absolute: Int) -> Int? {
        let line = absolute - scrollbackBase
        guard line >= 0, line < scrollbackCount + rows else { return nil }
        return line
    }

    /// Enforces `scrollbackLimit`, advancing `scrollbackBase` by whatever it
    /// discards. Every trim goes through here so the base cannot drift out of
    /// step with the ring.
    private mutating func trimScrollbackToLimit() {
        guard scrollbackCount > scrollbackLimit else { return }
        let excess = scrollbackCount - scrollbackLimit
        scrollbackHead += excess
        scrollbackBase += excess

        // Keep memory bounded without returning to removeFirst-on-every-line.
        // At most roughly twice the configured scrollback is retained between
        // compactions, and each element is moved only once per large batch.
        if scrollbackHead >= max(scrollbackLimit, 1), scrollbackHead * 2 >= scrollback.count {
            scrollback.removeFirst(scrollbackHead)
            scrollbackHead = 0
        }
    }

    init(rows: Int, columns: Int, scrollbackLimit: Int = 2000) {
        self.rows = max(rows, 1)
        self.columns = max(columns, 1)
        self.scrollbackLimit = max(scrollbackLimit, 0)
        self.regionBottom = self.rows - 1
        self.grid = Self.blankGrid(rows: self.rows, columns: self.columns)
    }

    private static func blankGrid(rows: Int, columns: Int) -> [TerminalLine] {
        Array(repeating: TerminalLine.blank(columns: columns), count: rows)
    }

    private var blankCell: TerminalCell { .blank(withBackgroundOf: brush) }

    // MARK: - Reading

    func cell(atRow row: Int, column: Int) -> TerminalCell {
        guard row >= 0, row < rows, column >= 0, column < columns else { return .blank }
        return grid[row][column]
    }

    func scrollbackLine(_ index: Int) -> [TerminalCell] {
        guard index >= 0, index < scrollbackCount else { return [] }
        return scrollback[scrollbackHead + index].cells
    }

    /// Whether the line at `contentLine` (scrollback lines first, then live grid
    /// rows) continues onto the line below because it autowrapped. Callers that
    /// join lines into text — copy, accessibility — must not insert a newline
    /// where this is true.
    func isLineWrapped(contentLine: Int) -> Bool {
        guard contentLine >= 0 else { return false }
        if contentLine < scrollbackCount { return scrollback[scrollbackHead + contentLine].wrapped }
        let row = contentLine - scrollbackCount
        guard row < rows, row < grid.count else { return false }
        return grid[row].wrapped
    }

    func lineText(_ row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return String(grid[row].cells.prefix(columns).filter { !$0.isContinuation }.map(\.character))
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
            cursorRow = clampRowWithinRegion(cursorRow + deltaRows, startingAt: cursorRow)
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
            eraseCells(in: cursorColumn..<end, row: cursorRow)
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
        if shouldExtendPreviousCell(with: character), appendToPreviousCell(character) {
            return
        }

        let width = Self.columnWidth(of: character)
        guard width > 0 else { return }

        if pendingWrap && autowrap {
            markCurrentLineWrapped()
            cursorColumn = 0
            lineFeed()
        }

        // A double-width grapheme cannot start in the final column. Wrap it
        // before drawing when possible; a one-column terminal degrades to a
        // single visible cell rather than corrupting the row.
        if width == 2, columns > 1, cursorColumn == columns - 1, autowrap {
            markCurrentLineWrapped(paddingColumns: 1)
            cursorColumn = 0
            lineFeed()
        }

        discardHiddenColumns(in: cursorRow)
        clearGlyph(atRow: cursorRow, column: cursorColumn)
        grid[cursorRow][cursorColumn] = TerminalCell(character: character, style: brush)

        if width == 2, cursorColumn + 1 < columns {
            clearGlyph(atRow: cursorRow, column: cursorColumn + 1)
            grid[cursorRow][cursorColumn + 1] = .continuation(with: brush)
            if cursorColumn + 1 == columns - 1 {
                cursorColumn = columns - 1
                pendingWrap = autowrap
            } else {
                cursorColumn += 2
            }
        } else if cursorColumn == columns - 1 {
            pendingWrap = autowrap
        } else {
            cursorColumn += 1
        }
    }

    /// Number of fixed terminal columns occupied by a grapheme. This is a
    /// deliberately compact wcwidth implementation covering combining marks,
    /// emoji sequences, and the East Asian wide/full-width ranges terminals
    /// encounter most often.
    nonisolated static func columnWidth(of character: Character) -> Int {
        // Printable ASCII is the overwhelming majority of terminal output and
        // always occupies exactly one column. Answering it without touching the
        // Unicode property tables keeps the print path off ICU lookups, which
        // dominate this function's cost.
        if let ascii = character.asciiValue, ascii >= 0x20, ascii != 0x7F {
            return 1
        }
        let scalars = character.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        if scalars.allSatisfy(isZeroWidth) { return 0 }
        if scalars.contains(where: isWide) { return 2 }
        return 1
    }

    private nonisolated static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return true
        default:
            break
        }

        switch scalar.value {
        case 0x1160...0x11FF, // Hangul Jamo medial/final
             0x1F3FB...0x1F3FF, // emoji skin-tone modifiers
             0xE0100...0xE01EF: // supplementary variation selectors
            return true
        default:
            return false
        }
    }

    private nonisolated static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             // East-Asian-Wide symbols outside the 0x1F300 emoji block. CLI
             // tools print these constantly for status -- a test runner's
             // check and cross, a spinner's clock faces -- and measuring them
             // as one column advances one less than the child computed, so
             // everything it positions later on that row is off by one.
             0x231A...0x231B, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653,
             0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4,
             0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD,
             0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E,
             0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF,
             0x2B1B...0x2B1C, 0x2B50, 0x2B55,
             0x2E80...0x303E,
             0x3040...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F1E6...0x1F1FF,
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD,
             0xFE0F: // emoji presentation selector in a larger grapheme
            return true
        default:
            return false
        }
    }

    private func previousBaseColumn() -> Int? {
        var column: Int
        if pendingWrap {
            column = cursorColumn
        } else {
            guard cursorColumn > 0 else { return nil }
            column = cursorColumn - 1
        }
        if grid[cursorRow][column].isContinuation {
            guard column > 0 else { return nil }
            column -= 1
        }
        return grid[cursorRow][column].isContinuation ? nil : column
    }

    private func shouldExtendPreviousCell(with character: Character) -> Bool {
        // Printable ASCII is never a combining mark, a ZWJ continuation, or a
        // regional indicator, so it can never extend the previous cell. This
        // early return keeps the common path free of grid reads entirely.
        if let ascii = character.asciiValue, ascii >= 0x20, ascii != 0x7F {
            return false
        }
        if Self.columnWidth(of: character) == 0 { return true }
        guard let column = previousBaseColumn() else { return false }
        let previousScalars = grid[cursorRow][column].character.unicodeScalars
        if previousScalars.last?.value == 0x200D { return true } // emoji ZWJ sequence

        guard character.unicodeScalars.allSatisfy(Self.isRegionalIndicator) else {
            return false
        }
        // Counted in place: `filter { }.count` heap-allocated an array on the
        // way to a number for every character reaching this path.
        var previousRegionalCount = 0
        for scalar in previousScalars where Self.isRegionalIndicator(scalar) {
            previousRegionalCount += 1
        }
        return previousRegionalCount % 2 == 1
    }

    private nonisolated static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    private mutating func appendToPreviousCell(_ character: Character) -> Bool {
        guard let column = previousBaseColumn() else { return false }
        let existing = grid[cursorRow][column].character
        if existing.unicodeScalars.count + character.unicodeScalars.count > Self.maximumScalarsPerCell {
            // Treat the extender as consumed so a wide ZWJ component cannot
            // spill into a new cell after the cap is reached.
            return true
        }
        let combinedText = String(existing) + String(character)
        guard combinedText.count == 1, let combined = combinedText.first else { return false }

        let oldWidth = Self.columnWidth(of: existing)
        let newWidth = Self.columnWidth(of: combined)
        if oldWidth == 1, newWidth == 2 {
            let continuationColumn = column + 1
            guard continuationColumn < columns else { return false }
            clearGlyph(atRow: cursorRow, column: continuationColumn)
            grid[cursorRow][continuationColumn] = .continuation(with: grid[cursorRow][column].style)
            if cursorColumn == continuationColumn {
                if continuationColumn == columns - 1 {
                    pendingWrap = autowrap
                } else {
                    cursorColumn += 1
                }
            }
        }
        grid[cursorRow][column].character = combined
        return true
    }

    private mutating func clearGlyph(atRow row: Int, column: Int) {
        guard row >= 0, row < grid.count, column >= 0, column < grid[row].count else { return }
        if grid[row][column].isContinuation {
            if column > 0 { grid[row][column - 1] = blankCell }
            grid[row][column] = blankCell
            return
        }
        grid[row][column] = blankCell
        if column + 1 < grid[row].count, grid[row][column + 1].isContinuation {
            grid[row][column + 1] = blankCell
        }
    }

    private mutating func eraseCells(in range: Range<Int>, row: Int) {
        for column in range { clearGlyph(atRow: row, column: column) }
    }

    private mutating func normalizeWideCells(in row: Int) {
        guard row >= 0, row < grid.count else { return }
        let limit = min(columns, grid[row].count)
        var column = 0
        while column < limit {
            let cell = grid[row][column]
            if cell.isContinuation {
                let hasBase = column > 0
                    && !grid[row][column - 1].isContinuation
                    && Self.columnWidth(of: grid[row][column - 1].character) == 2
                if !hasBase { grid[row][column] = blankCell }
                column += 1
                continue
            }
            if Self.columnWidth(of: cell.character) == 2 {
                guard column + 1 < limit, grid[row][column + 1].isContinuation else {
                    grid[row][column] = blankCell
                    column += 1
                    continue
                }
                column += 2
            } else {
                column += 1
            }
        }
    }

    /// Records that the current row's text continues on the row below. Called
    /// only where autowrap moves to the next line — an explicit newline must
    /// leave the flag clear, or copy joins two genuinely separate lines.
    private mutating func markCurrentLineWrapped(paddingColumns: Int = 0) {
        guard cursorRow >= 0, cursorRow < grid.count else { return }
        // A row can be revisited and wrapped a second time after cursor motion.
        // Retire any old marker before recording the new wrap geometry.
        for column in grid[cursorRow].cells.indices {
            grid[cursorRow][column].isWrapPadding = false
        }
        if paddingColumns > 0 {
            // Rows can retain hidden cells after a narrowing resize. Padding is
            // defined by the visible edge, not the backing row's old width.
            let visibleCellCount = min(columns, grid[cursorRow].count)
            let firstPaddingColumn = max(visibleCellCount - paddingColumns, 0)
            for column in firstPaddingColumn..<visibleCellCount {
                // Cursor addressing can revisit an occupied edge cell. The
                // wide glyph wraps without erasing that visible content, so it
                // is padding only when the cell is actually an unused blank.
                let cell = grid[cursorRow][column]
                if cell.character == " ", !cell.isContinuation, !cell.isExplicitContent {
                    grid[cursorRow][column].isWrapPadding = true
                }
            }
        }
        setCurrentLineWrapped(true)
    }

    private mutating func setCurrentLineWrapped(_ wrapped: Bool) {
        guard cursorRow >= 0, cursorRow < grid.count else { return }
        grid[cursorRow].wrapped = wrapped
        if !wrapped {
            for column in grid[cursorRow].cells.indices {
                grid[cursorRow][column].isWrapPadding = false
            }
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
            trimScrollbackToLimit()
        }

        for row in regionTop..<regionBottom {
            grid[row] = grid[row + 1]
        }
        grid[regionBottom] = TerminalLine.blank(columns: columns, filledWith: blankCell)
    }

    private mutating func scrollRegionDown() {
        var row = regionBottom
        while row > regionTop {
            grid[row] = grid[row - 1]
            row -= 1
        }
        grid[regionTop] = TerminalLine.blank(columns: columns, filledWith: blankCell)
    }

    // MARK: - Erase

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    grid[row] = TerminalLine.blank(columns: columns, filledWith: blankCell)
                }
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow {
                grid[row] = TerminalLine.blank(columns: columns, filledWith: blankCell)
            }
        case 2:
            grid = Array(repeating: TerminalLine.blank(columns: columns, filledWith: blankCell), count: rows)
        case 3:
            // xterm ED 3 erases saved lines only. Treat the removed lines as
            // evicted so absolute viewport/selection anchors cannot drift onto
            // unrelated content that later reuses their relative indices.
            scrollbackBase += scrollbackCount
            scrollback.removeAll(keepingCapacity: true)
            scrollbackHead = 0
        default:
            break
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        discardHiddenColumns(in: cursorRow)
        switch mode {
        case 0:
            eraseCells(in: cursorColumn..<columns, row: cursorRow)
            // The text that ran onto the next row has just been erased, so the
            // row no longer continues. Leaving the flag set would make copy
            // silently glue this row to the one below.
            setCurrentLineWrapped(false)
        case 1:
            // Erasing the start of the row leaves its tail, so whatever
            // continuation it had still stands.
            eraseCells(in: 0..<(min(cursorColumn, columns - 1) + 1), row: cursorRow)
        case 2:
            grid[cursorRow] = TerminalLine.blank(columns: columns, filledWith: blankCell)
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
            grid[cursorRow] = TerminalLine.blank(columns: columns, filledWith: blankCell)
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
            grid[regionBottom] = TerminalLine.blank(columns: columns, filledWith: blankCell)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private mutating func insertCharacters(_ amount: Int) {
        discardHiddenColumns(in: cursorRow)
        let count = min(max(amount, 1), columns - cursorColumn)
        var line = grid[cursorRow]
        line.cells.removeLast(count)
        line.cells.insert(contentsOf: Array(repeating: blankCell, count: count), at: cursorColumn)
        grid[cursorRow] = line
        normalizeWideCells(in: cursorRow)
    }

    private mutating func deleteCharacters(_ amount: Int) {
        discardHiddenColumns(in: cursorRow)
        let count = min(max(amount, 1), columns - cursorColumn)
        var line = grid[cursorRow]
        line.cells.removeSubrange(cursorColumn..<(cursorColumn + count))
        line.cells.append(contentsOf: Array(repeating: blankCell, count: count))
        grid[cursorRow] = line
        normalizeWideCells(in: cursorRow)
    }

    // MARK: - Modes

    private mutating func setMode(_ mode: TerminalMode, _ enabled: Bool) {
        switch mode {
        case .alternateScreen:
            guard enabled != usingAlternateScreen else { return }
            if enabled {
                savedPrimary = (grid, cursorRow, cursorColumn, savedCursor)
                grid = Array(repeating: TerminalLine.blank(columns: columns, filledWith: blankCell), count: rows)
                cursorRow = 0
                cursorColumn = 0
                // The alternate screen starts with no saved cursor of its own.
                savedCursor = nil
                usingAlternateScreen = true
            } else {
                if let saved = savedPrimary {
                    grid = saved.grid
                    cursorRow = clampRow(saved.cursorRow)
                    cursorColumn = clampColumn(saved.cursorColumn)
                    savedCursor = saved.savedCursor
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

        // Which existing row becomes the top of the new grid. Anchoring the
        // window on the cursor keeps the active prompt and the output above it
        // on screen. Anchoring on the bottom instead (the previous rule) kept
        // whatever trailing blank rows happened to exist and pushed the real
        // content into scrollback, so shrinking a normal shell session — whose
        // prompt sits near the top with blanks below — blanked the terminal.
        // Alternate-screen TUIs address rows absolutely, so they stay top-anchored.
        let firstRetained = usingAlternateScreen
            ? 0
            : max(0, min(cursorRow - targetRows + 1, grid.count - targetRows))

        // Rows scrolled off the top are preserved in scrollback (primary screen
        // only) so resizing smaller never loses text outright.
        if firstRetained > 0, scrollbackLimit > 0 {
            for row in 0..<firstRetained {
                scrollback.append(grid[row])
            }
            trimScrollbackToLimit()
        }

        // Preserve both primary and alternate-screen contents until the child
        // actually redraws them. Some TUIs repaint asynchronously after
        // SIGWINCH and some (including Hermes in the observed failure) do not
        // issue an immediate full repaint. Clearing the alternate grid here
        // therefore turns a routine resize into a permanently blank terminal.
        grid = Self.resizeGrid(
            grid,
            rows: targetRows,
            columns: targetColumns,
            firstRetained: firstRetained
        )
        if let saved = savedPrimary {
            // The parked primary screen is anchored on its own saved cursor.
            let savedDroppedTop = max(
                0,
                min(saved.cursorRow - targetRows + 1, saved.grid.count - targetRows)
            )
            // Bank the parked screen's dropped rows exactly as the live path
            // above does. Skipping this loses them from the grid *and* from
            // scrollback: shrink the window while a TUI holds the alternate
            // screen and the build output that scrolled off is unreachable
            // forever, even though the identical shrink at a shell prompt keeps
            // it.
            if savedDroppedTop > 0, scrollbackLimit > 0 {
                for row in 0..<min(savedDroppedTop, saved.grid.count) {
                    scrollback.append(saved.grid[row])
                }
                trimScrollbackToLimit()
            }
            savedPrimary = (
                Self.resizeGrid(
                    saved.grid,
                    rows: targetRows,
                    columns: targetColumns,
                    firstRetained: savedDroppedTop
                ),
                min(max(saved.cursorRow - savedDroppedTop, 0), targetRows - 1),
                min(saved.cursorColumn, targetColumns - 1),
                saved.savedCursor.map { cursor in
                    (
                        min(max(cursor.row - savedDroppedTop, 0), targetRows - 1),
                        min(cursor.column, targetColumns - 1)
                    )
                }
            )
        }

        // Rows are not reflowed, so a stored continuation no longer describes
        // the layout once the width changes: a widened row is padded with
        // blanks out to the new width, and copy deliberately skips the
        // trailing-blank trim for wrapped rows, which would inject that padding
        // into the middle of the copied text.
        if targetColumns != columns {
            for index in grid.indices { Self.clearWrapMetadata(in: &grid[index]) }
            for index in scrollbackHead..<scrollback.count {
                Self.clearWrapMetadata(in: &scrollback[index])
            }
            if var saved = savedPrimary {
                for index in saved.grid.indices { Self.clearWrapMetadata(in: &saved.grid[index]) }
                savedPrimary = saved
            }
        }

        rows = targetRows
        columns = targetColumns
        regionTop = 0
        regionBottom = rows - 1
        // The grid dropped `firstRetained` rows off the top, so move the cursor
        // up by the same amount to keep it on its own line.
        cursorRow = clampRow(cursorRow - firstRetained)
        cursorColumn = clampColumn(cursorColumn)
        pendingWrap = false
    }

    private static func clearWrapMetadata(in line: inout TerminalLine) {
        line.wrapped = false
        for index in line.cells.indices {
            line.cells[index].isWrapPadding = false
        }
    }

    /// Retains `rows` rows starting at `firstRetained`, padding each to at
    /// least `columns`. The caller picks the anchor: 0 for alternate-screen
    /// TUIs, and a cursor-derived offset for the primary screen so the active
    /// prompt stays visible instead of scrolling away behind blank rows.
    private static func resizeGrid(
        _ source: [TerminalLine],
        rows: Int,
        columns: Int,
        firstRetained: Int = 0
    ) -> [TerminalLine] {
        let start = min(max(firstRetained, 0), max(source.count - rows, 0))
        let retainedRows = source.dropFirst(start).prefix(rows)
        var result = retainedRows.map { line -> TerminalLine in
            // Keep cells beyond the temporarily visible width. If the user
            // widens the terminal again before that row is overwritten, its
            // right-hand content reappears instead of being destroyed.
            guard line.count < columns else { return line }
            return TerminalLine(
                cells: line.cells + Array(repeating: TerminalCell.blank, count: columns - line.count),
                wrapped: line.wrapped
            )
        }
        while result.count < rows {
            result.append(TerminalLine.blank(columns: columns))
        }
        return result
    }

    /// A row can retain hidden right-hand cells across a temporary narrowing.
    /// Once output mutates that row at the new width, discard the stale overflow
    /// so it cannot reappear after newer content has replaced the line.
    private mutating func discardHiddenColumns(in row: Int) {
        guard row >= 0, row < grid.count else { return }
        // A row already at the visible width has no stale overflow to drop, and
        // printing and erasing keep wide-cell pairs consistent on their own, so
        // the repair scan is only needed when this truncation can split a pair.
        // Skipping it here is what takes printing from O(columns) back to O(1):
        // printCharacter calls this for every glyph.
        guard grid[row].count > columns else { return }
        grid[row] = TerminalLine(cells: Array(grid[row].cells.prefix(columns)), wrapped: grid[row].wrapped)
        normalizeWideCells(in: row)
    }

    // MARK: - Clamping

    private func clampRow(_ row: Int) -> Int { min(max(row, 0), rows - 1) }
    private func clampColumn(_ column: Int) -> Int { min(max(column, 0), columns - 1) }

    /// CUU/CUD stop at the scroll-region margins when the cursor starts inside
    /// the region (DEC/xterm behavior). Without this a TUI's relative motion
    /// escapes DECSTBM and overwrites the header or status rows it reserved.
    /// A cursor already outside the region keeps plain grid clamping.
    private func clampRowWithinRegion(_ row: Int, startingAt origin: Int) -> Int {
        guard origin >= regionTop, origin <= regionBottom else { return clampRow(row) }
        return min(max(row, regionTop), regionBottom)
    }
}
