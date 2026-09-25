import Foundation

// Core value types shared by the terminal emulator's parser, screen model,
// and renderer. Pure data — no AppKit — so the logic layers stay testable
// with the dependency-free test runner.

enum TerminalColor: Equatable, Sendable {
    case defaultForeground
    case defaultBackground
    /// Standard + bright ANSI colors, index 0-15.
    case ansi(UInt8)
    /// xterm 256-color palette index (16-255 useful range).
    case palette(UInt8)
    /// 24-bit truecolor.
    case rgb(UInt8, UInt8, UInt8)
}

struct CellStyle: Equatable, Sendable {
    var foreground: TerminalColor = .defaultForeground
    var background: TerminalColor = .defaultBackground
    var bold = false
    var faint = false
    var italic = false
    var underline = false
    var inverse = false
    /// SGR 8 (xterm "invisible"): the renderer hides the glyphs, but the cell
    /// keeps its text so copy and accessibility behave as for any attribute.
    var concealed = false

    static let plain = CellStyle()
}

struct TerminalCell: Equatable, Sendable {
    var character: Character
    var style: CellStyle
    /// The trailing grid cell occupied by a double-width grapheme. Renderers
    /// skip its character while retaining its column for cursor/background
    /// geometry.
    var isContinuation: Bool
    /// True when the child explicitly printed this cell. This distinguishes an
    /// emitted space from an untouched grid blank when a later wide character
    /// has to wrap before the final column.
    var isExplicitContent: Bool
    /// An unused final column left behind when a double-width grapheme has to
    /// wrap before it. The cell remains part of the visual grid (and may carry
    /// a background), but it is not text the child emitted, so copy and
    /// accessibility omit it.
    var isWrapPadding: Bool

    init(
        character: Character,
        style: CellStyle,
        isContinuation: Bool = false,
        isWrapPadding: Bool = false,
        isExplicitContent: Bool = true
    ) {
        self.character = character
        self.style = style
        self.isContinuation = isContinuation
        self.isWrapPadding = isWrapPadding
        self.isExplicitContent = isExplicitContent
    }

    static let blank = TerminalCell(character: " ", style: .plain, isExplicitContent: false)

    static func continuation(with style: CellStyle) -> TerminalCell {
        TerminalCell(character: " ", style: style, isContinuation: true, isExplicitContent: false)
    }

    /// A blank cell that keeps the current background color, used when
    /// erasing so cleared regions match the active SGR background.
    static func blank(withBackgroundOf style: CellStyle) -> TerminalCell {
        var erased = CellStyle.plain
        erased.background = style.background
        return TerminalCell(character: " ", style: erased, isExplicitContent: false)
    }
}

/// Converts grid cells into user-visible text without leaking structural
/// cells into the clipboard or VoiceOver output.
enum TerminalRowText {
    /// The selected columns within one row, shared by highlighting and copy.
    /// Touching either half of a wide glyph selects the whole glyph. Returning
    /// nil preserves empty selections after a narrowing resize.
    static func selectedColumns(
        in cells: [TerminalCell],
        from firstColumn: Int,
        through lastColumn: Int
    ) -> Range<Int>? {
        guard !cells.isEmpty, firstColumn <= lastColumn,
              firstColumn < cells.count, lastColumn >= 0 else { return nil }
        var first = max(firstColumn, 0)
        var last = min(lastColumn, cells.count - 1)
        if first > 0, cells[first].isContinuation { first -= 1 }
        if last + 1 < cells.count, cells[last + 1].isContinuation { last += 1 }
        return first..<(last + 1)
    }

    static func string<C: Collection>(
        from cells: C,
        trimmingTrailingSpaces: Bool
    ) -> String where C.Element == TerminalCell {
        let text = String(
            cells.lazy
                .filter { !$0.isContinuation && !$0.isWrapPadding }
                .map(\.character)
        )
        guard trimmingTrailingSpaces else { return text }
        return String(text.reversed().drop(while: { $0 == " " }).reversed())
    }
}

enum TerminalMode: Equatable, Sendable {
    case alternateScreen
    case autowrap
    case bracketedPaste
    case cursorVisible
    case applicationCursorKeys
}

enum TerminalAction: Equatable, Sendable {
    /// ESC c (RIS): restore the emulator's complete initial state.
    case hardReset
    case print(Character)
    /// REP: print the character `count` more times, exactly as printing would.
    case repeatCharacter(Character, count: Int)
    case lineFeed
    case carriageReturn
    case backspace
    case tab
    case bell

    /// HTS: set a tab stop at the cursor column.
    case setTabStop
    /// TBC: 0 clears the stop at the cursor column, 3 clears every stop.
    case clearTabStops(Int)
    /// CHT / CBT: move to the Nth next or previous tab stop.
    case tabForward(Int)
    case tabBackward(Int)

    /// 1-based absolute positioning; nil leaves that axis unchanged (CHA/VPA).
    case moveCursor(row: Int?, column: Int?)
    /// Relative movement in rows/columns (CUU/CUD/CUF/CUB).
    case moveCursorRelative(rows: Int, columns: Int)

    /// Fully resolved SGR state (the parser tracks the running style).
    case setStyle(CellStyle)

    /// ED / EL with mode 0 (to end), 1 (to start), 2 (all).
    case eraseInDisplay(Int)
    case eraseInLine(Int)

    case insertLines(Int)
    case deleteLines(Int)
    case insertCharacters(Int)
    case deleteCharacters(Int)
    case eraseCharacters(Int)

    /// 1-based inclusive DECSTBM region.
    case setScrollRegion(top: Int, bottom: Int)
    case scrollUp(Int)
    case scrollDown(Int)

    case saveCursor
    case restoreCursor

    case setMode(TerminalMode, Bool)
    case setTitle(String)

    /// ESC M — move up, scrolling the region down at the top.
    case reverseIndex
    /// ESC D — move down, scrolling the region up at the bottom.
    case index
    /// ESC E — carriage return + index.
    case nextLine

    /// DSR: 5 = status, 6 = cursor position. Replies are the session's job.
    case reportDeviceStatus(Int)
}

/// Horizontal tab stops, one flag per column, as HTS/TBC program them and
/// HT/CHT/CBT consume them.
///
/// Like xterm's, the set outlives a narrowing resize: columns it hides keep
/// their stops, and only columns never seen before start with the default of
/// one stop every eight columns.
struct TerminalTabStops: Sendable {
    private static let defaultInterval = 8

    private var stops: [Bool]

    init(columns: Int) {
        stops = Self.defaultStops(for: 0..<max(columns, 0))
    }

    private static func defaultStops(for columns: Range<Int>) -> [Bool] {
        columns.map { $0 % defaultInterval == 0 }
    }

    /// Makes room for `columns`, giving only never-seen columns default stops.
    mutating func extend(toColumns columns: Int) {
        guard columns > stops.count else { return }
        stops += Self.defaultStops(for: stops.count..<columns)
    }

    func isStop(at column: Int) -> Bool {
        stops.indices.contains(column) && stops[column]
    }

    mutating func set(at column: Int) {
        guard stops.indices.contains(column) else { return }
        stops[column] = true
    }

    mutating func clear(at column: Int) {
        guard stops.indices.contains(column) else { return }
        stops[column] = false
    }

    mutating func clearAll() {
        stops = Array(repeating: false, count: stops.count)
    }

    /// The column `count` stops right of `column`. Running out of stops ends
    /// at `lastColumn`, the right margin, as xterm's HT and CHT do.
    func nextStop(after column: Int, count: Int, lastColumn: Int) -> Int {
        var position = column
        for _ in 0..<max(count, 1) {
            guard position < lastColumn else { break }
            position = ((position + 1)...lastColumn).first { isStop(at: $0) } ?? lastColumn
        }
        return position
    }

    /// The column `count` stops left of `column`, ending at the left margin.
    func previousStop(before column: Int, count: Int) -> Int {
        var position = column
        for _ in 0..<max(count, 1) {
            guard position > 0 else { break }
            position = (0..<position).last { isStop(at: $0) } ?? 0
        }
        return position
    }
}

/// One row of the terminal grid, plus whether its text continues onto the row
/// below because it autowrapped rather than being ended by an explicit newline.
///
/// The flag has to live on the row itself. A row filled exactly to the terminal
/// width looks identical whether it wrapped or the program sent a newline, so
/// nothing can be recovered from the cells afterwards — and copying a wrapped
/// path without knowing inserts a newline that breaks it when pasted. Carrying
/// the flag with the row means every scroll, resize, insert and alternate-screen
/// swap moves it along with its text for free, instead of a parallel array that
/// has to be kept in step at roughly two dozen call sites.
struct TerminalLine {
    var cells: [TerminalCell]
    /// True when this row's text continues on the row below.
    var wrapped: Bool

    init(cells: [TerminalCell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    static func blank(columns: Int, filledWith cell: TerminalCell = .blank) -> TerminalLine {
        TerminalLine(cells: Array(repeating: cell, count: max(columns, 0)))
    }

    var count: Int { cells.count }

    /// Cell access so the grid still reads as `grid[row][column]`.
    subscript(index: Int) -> TerminalCell {
        get { cells[index] }
        set { cells[index] = newValue }
    }
}

/// Joins selected terminal rows into clipboard text.
///
/// Lives here, apart from the AppKit selection code, so the rule that actually
/// matters — a soft-wrapped row must not gain a newline — is covered by tests.
enum TerminalTextJoiner {
    /// One selected row: its visible text, and whether the terminal wrapped it
    /// onto the row below rather than the program ending it with a newline.
    struct Row {
        var text: String
        var continuesToNextRow: Bool

        init(text: String, continuesToNextRow: Bool) {
            self.text = text
            self.continuesToNextRow = continuesToNextRow
        }
    }

    /// A wrapped row is joined to the next with nothing between them, so a path
    /// or command that merely overflowed the window comes back as one line and
    /// pastes correctly. Every other row keeps its newline.
    static func join(_ rows: [Row]) -> String {
        var output = ""
        for (index, row) in rows.enumerated() {
            output += row.text
            guard index < rows.count - 1 else { continue }
            if !row.continuesToNextRow { output += "\n" }
        }
        return output
    }
}

/// Converts between the terminal viewport's scroll offset and the absolute line
/// pinned to its top row.
///
/// A scroll offset counts up from the bottom of the buffer, so it names a
/// position that moves: every line of new output pushes the text the user
/// scrolled back to one row further up, and within a few seconds of streaming
/// output it has left the view entirely. Storing the absolute line at the top
/// instead (see `TerminalScreen.scrollbackBase`) keeps the reader still and lets
/// the offset be recomputed per frame.
///
/// Kept apart from the AppKit view so this arithmetic is covered by tests.
enum TerminalViewport {
    /// The absolute line that a given scroll offset puts at the top row.
    static func anchor(forOffset offset: Int, scrollbackBase: Int, scrollbackCount: Int) -> Int {
        let clamped = max(0, min(offset, max(scrollbackCount, 0)))
        return scrollbackBase + max(scrollbackCount, 0) - clamped
    }

    /// The scroll offset that puts `anchor` back on the top row. An anchor the
    /// ring has since discarded clamps to the oldest line still held, and one
    /// past the live grid clamps to the bottom, so a stale anchor degrades to
    /// the nearest sensible view instead of scrolling somewhere arbitrary.
    static func offset(forAnchor anchor: Int, scrollbackBase: Int, scrollbackCount: Int) -> Int {
        let available = max(scrollbackCount, 0)
        let raw = scrollbackBase + available - anchor
        return max(0, min(raw, available))
    }
}
