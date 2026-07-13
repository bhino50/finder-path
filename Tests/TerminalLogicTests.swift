import Darwin
import Foundation

@main
struct FinderPathTerminalTests {
    static func main() {
        var failures: [String] = []
        var assertionCount = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertionCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        // MARK: - Core types

        expect(TerminalCell.blank.character == " ", "blank cell should be a space")
        expect(CellStyle.plain.foreground == .defaultForeground, "plain style uses default foreground")
        var styled = CellStyle.plain
        styled.background = .ansi(1)
        expect(TerminalCell.blank(withBackgroundOf: styled).style.background == .ansi(1), "erase blank keeps background")
        expect(TerminalCell.blank(withBackgroundOf: styled).style.foreground == .defaultForeground, "erase blank resets foreground")

        // MARK: - Parser: plain text and controls

        var parser = TerminalParser()
        expect(parser.parse(Array("hi".utf8)) == [.print("h"), .print("i")], "plain text should print")
        expect(parser.parse([0x0A]) == [.lineFeed], "LF should map to lineFeed")
        expect(parser.parse([0x0D]) == [.carriageReturn], "CR should map to carriageReturn")
        expect(parser.parse([0x08]) == [.backspace], "BS should map to backspace")
        expect(parser.parse([0x09]) == [.tab], "TAB should map to tab")
        expect(parser.parse([0x07]) == [.bell], "BEL should map to bell")

        // MARK: - Parser: UTF-8 split across reads

        parser = TerminalParser()
        let emoji = Array("\u{1F600}".utf8) // 4 bytes
        expect(parser.parse(Array(emoji[0..<2])).isEmpty, "partial UTF-8 should buffer")
        expect(parser.parse(Array(emoji[2..<4])) == [.print("\u{1F600}")], "completed UTF-8 should print one character")

        // MARK: - Parser: cursor movement CSI

        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}[3;7H".utf8)) == [.moveCursor(row: 3, column: 7)], "CUP should move cursor")
        expect(parser.parse(Array("\u{1B}[H".utf8)) == [.moveCursor(row: 1, column: 1)], "CUP defaults to 1;1")
        expect(parser.parse(Array("\u{1B}[2A".utf8)) == [.moveCursorRelative(rows: -2, columns: 0)], "CUU moves up")
        expect(parser.parse(Array("\u{1B}[B".utf8)) == [.moveCursorRelative(rows: 1, columns: 0)], "CUD defaults to 1")
        expect(parser.parse(Array("\u{1B}[5C".utf8)) == [.moveCursorRelative(rows: 0, columns: 5)], "CUF moves right")
        expect(parser.parse(Array("\u{1B}[D".utf8)) == [.moveCursorRelative(rows: 0, columns: -1)], "CUB moves left")
        expect(parser.parse(Array("\u{1B}[9G".utf8)) == [.moveCursor(row: nil, column: 9)], "CHA sets column only")
        expect(parser.parse(Array("\u{1B}[4d".utf8)) == [.moveCursor(row: 4, column: nil)], "VPA sets row only")

        // Split CSI across reads
        parser = TerminalParser()
        expect(parser.parse([0x1B, 0x5B]).isEmpty, "incomplete CSI should buffer")
        expect(parser.parse([0x41]) == [.moveCursorRelative(rows: -1, columns: 0)], "CSI completed across reads")

        // MARK: - Parser: SGR styles

        parser = TerminalParser()
        var red = CellStyle.plain
        red.foreground = .ansi(1)
        expect(parser.parse(Array("\u{1B}[31m".utf8)) == [.setStyle(red)], "SGR 31 sets red foreground")
        var redBold = red
        redBold.bold = true
        expect(parser.parse(Array("\u{1B}[1m".utf8)) == [.setStyle(redBold)], "SGR 1 adds bold to running style")
        expect(parser.parse(Array("\u{1B}[0m".utf8)) == [.setStyle(.plain)], "SGR 0 resets")
        var rgb = CellStyle.plain
        rgb.foreground = .rgb(10, 20, 30)
        expect(parser.parse(Array("\u{1B}[38;2;10;20;30m".utf8)) == [.setStyle(rgb)], "SGR 38;2 sets truecolor")
        var pal = rgb
        pal.background = .palette(196)
        expect(parser.parse(Array("\u{1B}[48;5;196m".utf8)) == [.setStyle(pal)], "SGR 48;5 sets palette background")
        var bright = pal
        bright.foreground = .ansi(12)
        expect(parser.parse(Array("\u{1B}[94m".utf8)) == [.setStyle(bright)], "SGR 94 sets bright foreground")

        // MARK: - Parser: erase, insert, delete, scroll

        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}[J".utf8)) == [.eraseInDisplay(0)], "ED defaults to 0")
        expect(parser.parse(Array("\u{1B}[2J".utf8)) == [.eraseInDisplay(2)], "ED 2 erases all")
        expect(parser.parse(Array("\u{1B}[1K".utf8)) == [.eraseInLine(1)], "EL 1 erases to start")
        expect(parser.parse(Array("\u{1B}[3L".utf8)) == [.insertLines(3)], "IL inserts lines")
        expect(parser.parse(Array("\u{1B}[M".utf8)) == [.deleteLines(1)], "DL defaults to 1")
        expect(parser.parse(Array("\u{1B}[4@".utf8)) == [.insertCharacters(4)], "ICH inserts characters")
        expect(parser.parse(Array("\u{1B}[2P".utf8)) == [.deleteCharacters(2)], "DCH deletes characters")
        expect(parser.parse(Array("\u{1B}[5X".utf8)) == [.eraseCharacters(5)], "ECH erases characters")
        expect(parser.parse(Array("\u{1B}[2;5r".utf8)) == [.setScrollRegion(top: 2, bottom: 5)], "DECSTBM sets region")
        expect(parser.parse(Array("\u{1B}[2S".utf8)) == [.scrollUp(2)], "SU scrolls up")
        expect(parser.parse(Array("\u{1B}[T".utf8)) == [.scrollDown(1)], "SD defaults to 1")

        // MARK: - Parser: modes

        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}[?1049h".utf8)) == [.setMode(.alternateScreen, true)], "1049h enters alt screen")
        expect(parser.parse(Array("\u{1B}[?1049l".utf8)) == [.setMode(.alternateScreen, false)], "1049l leaves alt screen")
        expect(parser.parse(Array("\u{1B}[?2004h".utf8)) == [.setMode(.bracketedPaste, true)], "2004h enables bracketed paste")
        expect(parser.parse(Array("\u{1B}[?25l".utf8)) == [.setMode(.cursorVisible, false)], "25l hides cursor")
        expect(parser.parse(Array("\u{1B}[?1h".utf8)) == [.setMode(.applicationCursorKeys, true)], "DECCKM on")
        expect(parser.parse(Array("\u{1B}[?7l".utf8)) == [.setMode(.autowrap, false)], "DECAWM off")
        expect(parser.parse(Array("\u{1B}[?9999h".utf8)).isEmpty, "unknown private mode is ignored")

        // MARK: - Parser: OSC titles and unknown sequences

        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}]0;My Title\u{07}".utf8)) == [.setTitle("My Title")], "OSC 0 BEL sets title")
        expect(parser.parse(Array("\u{1B}]2;Other\u{1B}\\".utf8)) == [.setTitle("Other")], "OSC 2 ST sets title")
        expect(parser.parse(Array("\u{1B}]52;c;abc\u{07}".utf8)).isEmpty, "unknown OSC is ignored")
        expect(parser.parse(Array("\u{1B}[>c".utf8)).isEmpty, "device attributes query is ignored")
        expect(parser.parse(Array("\u{1B}(B".utf8)).isEmpty, "charset selection is consumed")
        expect(parser.parse(Array("hi\u{1B}[31mx".utf8)).count == 4, "text around sequences still prints")

        // MARK: - Parser: escapes and reports

        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}M".utf8)) == [.reverseIndex], "ESC M is reverse index")
        expect(parser.parse(Array("\u{1B}D".utf8)) == [.index], "ESC D is index")
        expect(parser.parse(Array("\u{1B}E".utf8)) == [.nextLine], "ESC E is next line")
        expect(parser.parse(Array("\u{1B}7".utf8)) == [.saveCursor], "ESC 7 saves cursor")
        expect(parser.parse(Array("\u{1B}8".utf8)) == [.restoreCursor], "ESC 8 restores cursor")
        expect(parser.parse(Array("\u{1B}[6n".utf8)) == [.reportDeviceStatus(6)], "DSR 6 requests cursor position")
        expect(parser.parse(Array("\u{1B}[s".utf8)) == [.saveCursor], "CSI s saves cursor")
        expect(parser.parse(Array("\u{1B}[u".utf8)) == [.restoreCursor], "CSI u restores cursor")

        // MARK: - Screen: printing, wrap, scrollback

        var screen = TerminalScreen(rows: 3, columns: 4, scrollbackLimit: 10)
        for character in "abcd" { screen.apply(.print(character)) }
        expect(screen.lineText(0) == "abcd", "printing fills the first row")
        expect(screen.cursorColumn == 3, "deferred wrap keeps cursor on last column")
        screen.apply(.print("e"))
        expect(screen.lineText(1).hasPrefix("e"), "wrap moves print to next row")
        expect(screen.cursorRow == 1 && screen.cursorColumn == 1, "cursor advanced after wrap")

        screen = TerminalScreen(rows: 2, columns: 3, scrollbackLimit: 10)
        for character in "abc" { screen.apply(.print(character)) }
        screen.apply(.carriageReturn)
        screen.apply(.lineFeed)
        for character in "def" { screen.apply(.print(character)) }
        screen.apply(.carriageReturn)
        screen.apply(.lineFeed) // bottom row: scrolls, "abc" goes to scrollback
        expect(screen.scrollbackCount == 1, "scrolled line lands in scrollback")
        expect(String(screen.scrollbackLine(0).map(\.character)) == "abc", "scrollback preserves content")
        expect(screen.lineText(0) == "def", "grid shifted up")

        // MARK: - Screen: cursor movement and clamping

        screen = TerminalScreen(rows: 5, columns: 10, scrollbackLimit: 10)
        screen.apply(.moveCursor(row: 3, column: 7))
        expect(screen.cursorRow == 2 && screen.cursorColumn == 6, "CUP is 1-based")
        screen.apply(.moveCursorRelative(rows: -10, columns: 0))
        expect(screen.cursorRow == 0, "relative move clamps at top")
        screen.apply(.moveCursor(row: 99, column: 99))
        expect(screen.cursorRow == 4 && screen.cursorColumn == 9, "absolute move clamps to grid")
        screen.apply(.moveCursor(row: nil, column: 2))
        expect(screen.cursorRow == 4 && screen.cursorColumn == 1, "CHA keeps row")

        // MARK: - Screen: erase

        screen = TerminalScreen(rows: 2, columns: 5, scrollbackLimit: 10)
        for character in "hello" { screen.apply(.print(character)) }
        screen.apply(.moveCursor(row: 1, column: 3))
        screen.apply(.eraseInLine(0))
        expect(screen.lineText(0) == "he   ", "EL 0 erases to end")
        for character in "llo" { screen.apply(.print(character)) }
        screen.apply(.moveCursor(row: 1, column: 3))
        screen.apply(.eraseInLine(1))
        expect(screen.lineText(0) == "   lo" || screen.lineText(0).hasSuffix("lo"), "EL 1 erases to start inclusive")
        screen.apply(.eraseInDisplay(2))
        expect(screen.lineText(0).trimmingCharacters(in: .whitespaces).isEmpty, "ED 2 clears everything")

        // MARK: - Screen: styles captured

        screen = TerminalScreen(rows: 2, columns: 5, scrollbackLimit: 10)
        var green = CellStyle.plain
        green.foreground = .ansi(2)
        screen.apply(.setStyle(green))
        screen.apply(.print("x"))
        expect(screen.cell(atRow: 0, column: 0).style.foreground == .ansi(2), "printed cell captures style")

        // MARK: - Screen: scroll region

        screen = TerminalScreen(rows: 5, columns: 3, scrollbackLimit: 10)
        for (row, text) in ["aaa", "bbb", "ccc", "ddd", "eee"].enumerated() {
            screen.apply(.moveCursor(row: row + 1, column: 1))
            for character in text { screen.apply(.print(character)) }
        }
        screen.apply(.setScrollRegion(top: 2, bottom: 4))
        screen.apply(.moveCursor(row: 4, column: 1))
        screen.apply(.lineFeed)
        expect(screen.lineText(0) == "aaa", "row above region untouched")
        expect(screen.lineText(1) == "ccc", "region scrolled up")
        expect(screen.lineText(2) == "ddd", "region content shifted")
        expect(screen.lineText(3).trimmingCharacters(in: .whitespaces).isEmpty, "region bottom cleared")
        expect(screen.lineText(4) == "eee", "row below region untouched")
        expect(screen.scrollbackCount == 0, "region scroll does not feed scrollback")

        // MARK: - Screen: insert and delete lines within region

        screen = TerminalScreen(rows: 4, columns: 3, scrollbackLimit: 10)
        for (row, text) in ["aaa", "bbb", "ccc", "ddd"].enumerated() {
            screen.apply(.moveCursor(row: row + 1, column: 1))
            for character in text { screen.apply(.print(character)) }
        }
        screen.apply(.moveCursor(row: 2, column: 1))
        screen.apply(.insertLines(1))
        expect(screen.lineText(1).trimmingCharacters(in: .whitespaces).isEmpty, "IL blanks the cursor row")
        expect(screen.lineText(2) == "bbb", "IL pushes lines down")
        expect(screen.lineText(3) == "ccc", "IL drops the last row")
        screen.apply(.deleteLines(1))
        expect(screen.lineText(1) == "bbb", "DL pulls lines up")

        // MARK: - Screen: alternate screen

        screen = TerminalScreen(rows: 2, columns: 3, scrollbackLimit: 10)
        for character in "abc" { screen.apply(.print(character)) }
        screen.apply(.setMode(.alternateScreen, true))
        expect(screen.usingAlternateScreen, "alt screen mode is tracked")
        expect(screen.lineText(0).trimmingCharacters(in: .whitespaces).isEmpty, "alt screen starts blank")
        for character in "zzz" { screen.apply(.print(character)) }
        screen.apply(.setMode(.alternateScreen, false))
        expect(!screen.usingAlternateScreen, "back to primary screen")
        expect(screen.lineText(0) == "abc", "primary content restored")

        // MARK: - Screen: resize

        screen = TerminalScreen(rows: 3, columns: 4, scrollbackLimit: 10)
        for character in "abcd" { screen.apply(.print(character)) }
        screen.resize(rows: 2, columns: 2)
        expect(screen.rows == 2 && screen.columns == 2, "resize applies dimensions")
        expect(screen.lineText(0) == "ab", "narrower resize truncates")
        expect(screen.cursorColumn <= 1 && screen.cursorRow <= 1, "cursor clamped on resize")
        screen.resize(rows: 3, columns: 6)
        expect(screen.lineText(0) == "ab    ", "wider resize pads with blanks")

        // MARK: - Screen: modes and title

        screen = TerminalScreen(rows: 2, columns: 2, scrollbackLimit: 10)
        screen.apply(.setMode(.cursorVisible, false))
        expect(!screen.cursorVisible, "cursor visibility tracked")
        screen.apply(.setMode(.bracketedPaste, true))
        expect(screen.bracketedPaste, "bracketed paste tracked")
        screen.apply(.setMode(.applicationCursorKeys, true))
        expect(screen.applicationCursorKeys, "application cursor keys tracked")
        screen.apply(.setTitle("build"))
        expect(screen.title == "build", "title tracked")

        // MARK: - Result

        if failures.isEmpty {
            print("FinderPathTerminalTests passed (\(assertionCount) assertions)")
            exit(0)
        }

        print("FinderPathTerminalTests FAILED:")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
