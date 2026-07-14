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

    static let blank = TerminalCell(character: " ", style: .plain)

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
