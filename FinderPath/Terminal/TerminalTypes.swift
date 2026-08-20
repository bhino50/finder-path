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

    static let plain = CellStyle()
}

struct TerminalCell: Equatable, Sendable {
    var character: Character
    var style: CellStyle
    /// The trailing grid cell occupied by a double-width grapheme. Renderers
    /// skip its character while retaining its column for cursor/background
    /// geometry.
    var isContinuation: Bool

    init(character: Character, style: CellStyle, isContinuation: Bool = false) {
        self.character = character
        self.style = style
        self.isContinuation = isContinuation
    }

    static let blank = TerminalCell(character: " ", style: .plain)

    static func continuation(with style: CellStyle) -> TerminalCell {
        TerminalCell(character: " ", style: style, isContinuation: true)
    }

    /// A blank cell that keeps the current background color, used when
    /// erasing so cleared regions match the active SGR background.
    static func blank(withBackgroundOf style: CellStyle) -> TerminalCell {
        var erased = CellStyle.plain
        erased.background = style.background
        return TerminalCell(character: " ", style: erased)
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
    case lineFeed
    case carriageReturn
    case backspace
    case tab
    case bell

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
