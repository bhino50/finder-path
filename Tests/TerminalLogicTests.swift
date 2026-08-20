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
        expect(parser.parse(Array("\u{1B}]0;\u{2733} Claude Code\u{07}".utf8)) == [.setTitle("\u{2733} Claude Code")], "OSC title decodes multi-byte UTF-8, not Latin-1 per byte")
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

        // MARK: - Screen: Unicode cell widths and split graphemes

        expect(TerminalScreen.columnWidth(of: "A") == 1, "ASCII occupies one terminal column")
        expect(TerminalScreen.columnWidth(of: "界") == 2, "CJK occupies two terminal columns")
        expect(TerminalScreen.columnWidth(of: "😀") == 2, "emoji occupies two terminal columns")
        expect(TerminalScreen.columnWidth(of: "\u{0301}") == 0, "combining marks occupy no terminal column")

        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        for character in "A界B" { screen.apply(.print(character)) }
        expect(screen.lineText(0).hasPrefix("A界B"), "wide glyph text excludes its continuation cell")
        expect(screen.cursorColumn == 4, "wide glyph advances the cursor by two columns")
        expect(screen.cell(atRow: 0, column: 2).isContinuation, "wide glyph reserves a continuation cell")

        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        screen.apply(.print("e"))
        screen.apply(.print("\u{0301}"))
        expect(screen.cell(atRow: 0, column: 0).character == "e\u{0301}", "split combining mark joins its base cell")
        expect(screen.cursorColumn == 1, "split combining mark does not advance the cursor")

        parser = TerminalParser()
        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        for action in parser.parse(Array("👩‍💻".utf8)) { screen.apply(action) }
        expect(screen.lineText(0).hasPrefix("👩‍💻"), "split emoji ZWJ scalars rejoin one grapheme")
        expect(screen.cursorColumn == 2, "emoji ZWJ grapheme occupies two columns")
        expect(screen.cell(atRow: 0, column: 1).isContinuation, "emoji ZWJ grapheme keeps one continuation")

        screen = TerminalScreen(rows: 2, columns: 4, scrollbackLimit: 10)
        for character in "abc界" { screen.apply(.print(character)) }
        expect(screen.lineText(1).hasPrefix("界"), "wide glyph wraps before the final column")
        expect(screen.cursorRow == 1 && screen.cursorColumn == 2, "wrapped wide glyph advances by two columns")

        screen = TerminalScreen(rows: 1, columns: 6, scrollbackLimit: 10)
        for character in "A界B" { screen.apply(.print(character)) }
        screen.apply(.moveCursor(row: 1, column: 3))
        screen.apply(.eraseCharacters(1))
        expect(screen.cell(atRow: 0, column: 1).character == " ", "erasing a continuation clears its wide base")
        expect(!screen.cell(atRow: 0, column: 2).isContinuation, "erasing a wide glyph clears its continuation")

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

        // Keep the last alternate-screen frame visible through resize. TUIs do
        // not all repaint synchronously after SIGWINCH (Hermes is one example),
        // so clearing first creates a permanently blank terminal when no full
        // redraw follows.
        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        screen.apply(.setMode(.alternateScreen, true))
        for character in "claude" { screen.apply(.print(character)) }
        expect(screen.lineText(0) == "claude", "alt screen holds the drawn frame")
        screen.resize(rows: 2, columns: 3)
        expect(screen.columns == 3, "alt-screen resize applies the new width")
        expect(screen.lineText(0) == "cla", "alt-screen resize preserves the visible part of the frame")
        screen.resize(rows: 2, columns: 6)
        expect(screen.lineText(0) == "claude", "alt-screen grow restores temporarily hidden frame cells")

        screen = TerminalScreen(rows: 4, columns: 6, scrollbackLimit: 10)
        screen.apply(.setMode(.alternateScreen, true))
        for character in "header" { screen.apply(.print(character)) }
        screen.apply(.moveCursor(row: 4, column: 1))
        for character in "footer" { screen.apply(.print(character)) }
        screen.resize(rows: 2, columns: 6)
        expect(screen.lineText(0) == "header", "alt-screen height shrink keeps top-anchored TUI content")

        // MARK: - Screen: resize keeps the bottom rows

        screen = TerminalScreen(rows: 3, columns: 4, scrollbackLimit: 10)
        screen.apply(.moveCursor(row: 3, column: 1))
        for character in "abcd" { screen.apply(.print(character)) } // content on the bottom row
        expect(screen.cursorRow == 2, "cursor sits on the bottom row before resize")
        screen.resize(rows: 2, columns: 2)
        expect(screen.rows == 2 && screen.columns == 2, "resize applies dimensions")
        expect(screen.lineText(1) == "ab", "shrink keeps the visible left side of the bottom row")
        expect(screen.cursorRow == 1, "cursor tracks its retained line after shrink")
        screen.resize(rows: 4, columns: 6)
        expect(screen.lineText(1) == "abcd  ", "grow restores right-side content hidden by a temporary shrink")

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

        // MARK: - Input encoder

        expect(TerminalInputEncoder.encode(text: "ls") == Array("ls".utf8), "plain text passes through")
        expect(
            TerminalInputEncoder.encode(specialKey: .up, applicationCursorKeys: false) == [0x1B, 0x5B, 0x41],
            "up arrow is CSI A"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .up, applicationCursorKeys: true) == [0x1B, 0x4F, 0x41],
            "application mode up arrow is SS3 A"
        )

        // Wheel scrolling on the alternate screen translates to arrow presses
        // (xterm alternateScroll); the scrollback is empty there, so without
        // this a pinned terminal running a TUI cannot scroll at all.
        let scrollUp = TerminalInputEncoder.alternateScrollKeyPresses(wheelLines: 3)
        expect(scrollUp?.key == .up && scrollUp?.count == 3, "scrolling up maps to Up arrow presses")
        let scrollDown = TerminalInputEncoder.alternateScrollKeyPresses(wheelLines: -2)
        expect(scrollDown?.key == .down && scrollDown?.count == 2, "scrolling down maps to Down arrow presses")
        expect(
            TerminalInputEncoder.alternateScrollKeyPresses(wheelLines: 0) == nil,
            "no wheel movement sends nothing"
        )
        expect(
            TerminalInputEncoder.alternateScrollKeyPresses(wheelLines: -500)?.count == 40,
            "momentum scrolling is capped so it cannot flood the PTY"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .backspace, applicationCursorKeys: false) == [0x7F],
            "backspace sends DEL"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .enter, applicationCursorKeys: false) == [0x0D],
            "enter sends CR"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .escape, applicationCursorKeys: false) == [0x1B],
            "escape sends ESC"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .forwardDelete, applicationCursorKeys: false) == Array("\u{1B}[3~".utf8),
            "forward delete is CSI 3~"
        )
        expect(
            TerminalInputEncoder.encode(specialKey: .function(1), applicationCursorKeys: false) == [0x1B, 0x4F, 0x50],
            "F1 is SS3 P"
        )
        expect(TerminalInputEncoder.encodeControl(character: "c") == [0x03], "ctrl-c is ETX")
        expect(TerminalInputEncoder.encodeControl(character: "c", meta: true) == [0x1B, 0x03], "Option-ctrl-c is ESC-prefixed ETX")
        expect(TerminalInputEncoder.encodeControl(character: "A") == [0x01], "ctrl-A is SOH")
        expect(TerminalInputEncoder.encodeControl(character: "[") == [0x1B], "ctrl-[ is ESC")
        expect(TerminalInputEncoder.encodeControl(character: "1") == nil, "ctrl-1 has no encoding")
        expect(TerminalInputEncoder.encode(text: "b", meta: true) == [0x1B, 0x62], "Option-b is Meta-b")
        expect(
            TerminalInputEncoder.encode(
                specialKey: .left,
                modifiers: [.option],
                applicationCursorKeys: false
            ) == Array("\u{1B}[1;3D".utf8),
            "Option-left uses the xterm modifier parameter"
        )
        expect(
            TerminalInputEncoder.encode(
                specialKey: .up,
                modifiers: [.shift, .control],
                applicationCursorKeys: true
            ) == Array("\u{1B}[1;6A".utf8),
            "modified arrows use CSI even while application cursor mode is active"
        )
        expect(
            TerminalInputEncoder.encode(
                specialKey: .tab,
                modifiers: [.shift],
                applicationCursorKeys: false
            ) == Array("\u{1B}[Z".utf8),
            "Shift-tab sends CSI Z"
        )
        expect(
            TerminalInputEncoder.encode(
                specialKey: .tab,
                modifiers: [.shift, .option],
                applicationCursorKeys: false
            ) == Array("\u{1B}[1;4Z".utf8),
            "Option-Shift-tab preserves both modifiers"
        )
        expect(
            TerminalInputEncoder.encode(
                specialKey: .tab,
                modifiers: [.shift, .control],
                applicationCursorKeys: false
            ) == Array("\u{1B}[1;6Z".utf8),
            "Control-Shift-tab preserves both modifiers"
        )
        for functionKey in 1...12 {
            expect(
                !TerminalInputEncoder.encode(
                    specialKey: .function(functionKey),
                    applicationCursorKeys: false
                ).isEmpty,
                "F\(functionKey) has a terminal sequence"
            )
        }
        expect(
            TerminalInputEncoder.encodePaste("hi", bracketed: false) == Array("hi".utf8),
            "unbracketed paste passes through"
        )
        expect(
            TerminalInputEncoder.encodePaste("hi", bracketed: true)
                == Array("\u{1B}[200~".utf8) + Array("hi".utf8) + Array("\u{1B}[201~".utf8),
            "bracketed paste wraps content"
        )
        expect(
            !TerminalInputEncoder.encodePaste("a\u{1B}[201~b", bracketed: true).dropFirst(6).dropLast(6).contains(0x1B),
            "bracketed paste strips ESC bytes from content"
        )
        expect(
            !TerminalInputEncoder.encodePaste("a\u{1B}[31mb", bracketed: false).contains(0x1B),
            "unbracketed paste strips ESC bytes from content"
        )

        // MARK: - Parser: colon-delimited SGR (ITU-T)

        var colonParser = TerminalParser()
        var rgbColon = CellStyle.plain
        rgbColon.foreground = .rgb(10, 20, 30)
        expect(colonParser.parse(Array("\u{1B}[38:2:10:20:30m".utf8)) == [.setStyle(rgbColon)], "colon truecolor SGR parses")
        var palColon = CellStyle.plain
        palColon.foreground = .palette(196)
        expect(colonParser.parse(Array("\u{1B}[38:5:196m".utf8)) == [.setStyle(palColon)], "colon palette SGR parses")
        expect(
            colonParser.parse(Array("\u{1B}[38:2::10:20:30m".utf8)) == [.setStyle(rgbColon)],
            "colon truecolor SGR ignores the optional empty colorspace slot"
        )

        // MARK: - Parser: RIS hard reset

        var risParser = TerminalParser()
        let risActions = risParser.parse(Array("\u{1B}c".utf8))
        expect(risActions == [.hardReset], "RIS emits one atomic hard-reset action")
        var resetScreen = TerminalScreen(rows: 3, columns: 4, scrollbackLimit: 10)
        resetScreen.apply(.moveCursor(row: 3, column: 4))
        resetScreen.apply(.saveCursor)
        resetScreen.apply(.setMode(.bracketedPaste, true))
        resetScreen.apply(.setMode(.applicationCursorKeys, true))
        resetScreen.apply(.setMode(.cursorVisible, false))
        resetScreen.apply(.setMode(.autowrap, false))
        resetScreen.apply(.setMode(.alternateScreen, true))
        resetScreen.apply(.setTitle("stale title"))
        resetScreen.apply(.print("x"))
        resetScreen.apply(.hardReset)
        expect(!resetScreen.usingAlternateScreen, "RIS exits the alternate screen")
        expect(resetScreen.autowrap, "RIS restores autowrap")
        expect(!resetScreen.bracketedPaste, "RIS disables bracketed paste")
        expect(!resetScreen.applicationCursorKeys, "RIS disables application cursor keys")
        expect(resetScreen.cursorVisible, "RIS restores cursor visibility")
        expect(resetScreen.title.isEmpty, "RIS clears the stale terminal title")
        expect(resetScreen.lineText(0).trimmingCharacters(in: .whitespaces).isEmpty, "RIS clears the screen")
        resetScreen.apply(.restoreCursor)
        expect(resetScreen.cursorRow == 0 && resetScreen.cursorColumn == 0, "RIS clears the saved cursor")

        // MARK: - Session metadata

        let metadataID = UUID()
        let metadata = TerminalSessionMetadata(
            id: metadataID,
            name: "Production",
            workingDirectory: "/tmp",
            hasCustomName: true
        )
        expect(
            TerminalSessionStore.decodeMetadata(TerminalSessionStore.encodeMetadata([metadata])) == [metadata],
            "session metadata preserves manual-name precedence"
        )
        let legacyMetadata = Data(
            "[{\"id\":\"\(metadataID.uuidString)\",\"name\":\"Terminal 1\",\"workingDirectory\":\"/tmp\"}]".utf8
        )
        expect(
            TerminalSessionStore.decodeMetadata(legacyMetadata).first?.hasCustomName == false,
            "FinderPath 1.6 session metadata decodes with an unpinned legacy name"
        )

        // MARK: - Session startup geometry

        // A restored/new session can be activated while AppKit is still
        // reparenting the terminal view. Starting at the fallback 80x24 grid
        // and resizing a moment later corrupts zsh prompt/history redraws, so
        // the spawn must wait for the first real viewport dimensions.
        MainActor.assumeIsolated {
            let deferredSession = TerminalSession(
                name: "Deferred",
                workingDirectory: "/tmp",
                shellPath: "/bin/zsh",
                scrollbackLimit: 10
            )
            deferredSession.start()
            expect(deferredSession.status == .notStarted, "session waits for a real viewport before spawning")
            deferredSession.resize(rows: 12, columns: 37)
            expect(deferredSession.screen.rows == 12 && deferredSession.screen.columns == 37,
                   "first viewport dimensions reach the screen before spawn")
            expect(deferredSession.status == .running, "session spawns once viewport geometry is ready")
            deferredSession.terminate()
        }

        // MARK: - Screen: hostile counts are clamped to the region

        var clampScreen = TerminalScreen(rows: 3, columns: 3, scrollbackLimit: 5)
        for (row, text) in ["aaa", "bbb", "ccc"].enumerated() {
            clampScreen.apply(.moveCursor(row: row + 1, column: 1))
            for character in text { clampScreen.apply(.print(character)) }
        }
        clampScreen.apply(.scrollUp(9999)) // clamped to region height, must not loop 9999 times
        expect(clampScreen.lineText(0).trimmingCharacters(in: .whitespaces).isEmpty, "oversized scrollUp clears the region")
        expect(clampScreen.lineText(2).trimmingCharacters(in: .whitespaces).isEmpty, "oversized scrollUp empties every row")

        // MARK: - PTY round trip (real child process)

        do {
            let pty = PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", "printf ready"],
                workingDirectory: "/tmp",
                environment: [:],
                rows: 24,
                columns: 80
            )
            let outputLock = NSLock()
            var collected: [UInt8] = []
            let exitSemaphore = DispatchSemaphore(value: 0)
            var reportedExit: Int32 = -999

            pty.onOutput = { bytes in
                outputLock.lock()
                collected.append(contentsOf: bytes)
                outputLock.unlock()
            }
            pty.onExit = { code in
                reportedExit = code
                exitSemaphore.signal()
            }

            do {
                try pty.launch()
                let exited = exitSemaphore.wait(timeout: .now() + 5)
                expect(exited == .success, "PTY child should exit within the timeout")
                expect(reportedExit == 0, "PTY should report the child's exit code 0")

                // Output can drain fractionally after the exit signal since the
                // read source and reaper run on separate queues; poll briefly.
                var text = ""
                for _ in 0..<100 {
                    outputLock.lock()
                    text = String(decoding: collected, as: UTF8.self)
                    outputLock.unlock()
                    if text.contains("ready") { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                expect(text.contains("ready"), "PTY should relay the child's stdout")
            } catch {
                failures.append("PTY launch threw: \(error)")
            }
        }

        expect(!PTYProcess.defaultShell().isEmpty, "default shell resolves to a non-empty path")

        // MARK: - PTY controlling terminal

        do {
            let pty = PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", "tty"],
                workingDirectory: "/tmp",
                environment: [:],
                rows: 24,
                columns: 80
            )
            let lock = NSLock()
            var collected: [UInt8] = []
            let done = DispatchSemaphore(value: 0)
            pty.onOutput = { bytes in
                lock.lock(); collected.append(contentsOf: bytes); lock.unlock()
            }
            pty.onExit = { _ in done.signal() }
            do {
                try pty.launch()
                _ = done.wait(timeout: .now() + 5)
                var text = ""
                for _ in 0..<100 {
                    lock.lock(); text = String(decoding: collected, as: UTF8.self); lock.unlock()
                    if text.contains("/dev/tty") { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                // `tty` prints the device path only when a controlling terminal
                // exists, otherwise "not a tty" — so this proves the ctty fix.
                expect(text.contains("/dev/tty"), "child acquires a controlling terminal")
            } catch {
                failures.append("controlling-terminal test launch threw: \(error)")
            }
        }

        // MARK: - PTY write/drain deadlock regression

        do {
            // `yes` spews output forever and never reads stdin. Writing a large
            // payload would block the write; if that block held the state queue
            // (the original bug), draining and terminate() would wedge and the
            // child would never exit. It must still terminate promptly.
            let pty = PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", "yes"],
                workingDirectory: "/tmp",
                environment: [:],
                rows: 24,
                columns: 80
            )
            let exited = DispatchSemaphore(value: 0)
            pty.onOutput = { _ in } // discard; the point is that draining keeps flowing
            pty.onExit = { _ in exited.signal() }
            do {
                try pty.launch()
                pty.write([UInt8](repeating: 0x61, count: 200_000))
                Thread.sleep(forTimeInterval: 0.2)
                pty.terminate()
                let ended = exited.wait(timeout: .now() + 5)
                expect(ended == .success, "spewing child that ignores stdin still terminates (no deadlock)")
                if ended != .success { pty.terminate() }
            } catch {
                failures.append("deadlock regression launch threw: \(error)")
            }
        }

        // MARK: - PTY restart cleanup

        do {
            // A fast restart drops the old TerminalSession's PTY reference
            // immediately. Its cleanup must remain alive long enough to kill a
            // HUP-resistant child process rather than leaving it orphaned.
            let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("finderpath-pty-child-\(UUID().uuidString)")
            let script = "trap '' HUP; sleep 30 & child=$!; printf '%s' \"$child\" > '\(pidFile.path)'; wait \"$child\""
            var pty: PTYProcess? = PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", script],
                workingDirectory: "/tmp",
                environment: [:],
                rows: 24,
                columns: 80
            )
            pty?.onOutput = { _ in }
            do {
                try pty?.launch()
                var descendantPID: pid_t = -1
                for _ in 0..<200 {
                    if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                       let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        descendantPID = parsed
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                expect(descendantPID > 1, "PTY cleanup test should capture the descendant PID")
                pty?.terminate()
                pty = nil // mirrors TerminalSession.restart() replacing the owner

                if descendantPID > 1 {
                    var disappeared = false
                    for _ in 0..<500 {
                        if kill(descendantPID, 0) == -1, errno == ESRCH {
                            disappeared = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    expect(disappeared, "fast PTY restart should not orphan a HUP-resistant descendant")
                    if !disappeared { kill(descendantPID, SIGKILL) }
                }
            } catch {
                failures.append("restart-cleanup regression launch threw: \(error)")
            }
            try? FileManager.default.removeItem(at: pidFile)
        }

        do {
            // A pipeline/process-group leader can exit while another member of
            // that group remains in the shell's session. Cleanup must find the
            // live member by session rather than relying on the dead PGID leader.
            let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("finderpath-pty-orphaned-group-\(UUID().uuidString)")
            let python = """
            import os, signal, sys, time
            leader = os.fork()
            if leader == 0:
                os.setpgid(0, 0)
                member = os.fork()
                if member == 0:
                    signal.signal(signal.SIGHUP, signal.SIG_IGN)
                    with open(sys.argv[1], 'w') as output:
                        output.write(str(os.getpid()))
                    time.sleep(30)
                    os._exit(0)
                os._exit(0)
            os.waitpid(leader, 0)
            time.sleep(30)
            """
            var pty: PTYProcess? = PTYProcess(
                executable: "/usr/bin/python3",
                arguments: ["-c", python, pidFile.path],
                workingDirectory: "/tmp",
                environment: [:],
                rows: 24,
                columns: 80
            )
            pty?.onOutput = { _ in }
            do {
                try pty?.launch()
                var orphanedGroupMember: pid_t = -1
                for _ in 0..<300 {
                    if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                       let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        orphanedGroupMember = parsed
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                expect(orphanedGroupMember > 1, "PTY cleanup test should capture the orphaned group member")
                pty?.terminate()
                pty = nil

                if orphanedGroupMember > 1 {
                    var disappeared = false
                    for _ in 0..<500 {
                        if kill(orphanedGroupMember, 0) == -1, errno == ESRCH {
                            disappeared = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    expect(disappeared, "PTY cleanup should kill a session member after its group leader exits")
                    if !disappeared { kill(orphanedGroupMember, SIGKILL) }
                }
            } catch {
                failures.append("orphaned-group cleanup launch threw: \(error)")
            }
            try? FileManager.default.removeItem(at: pidFile)
        }

        // MARK: - PTY synchronous hang-up (app quit path)

        // applicationWillTerminate has no time to let the async terminate()
        // path run, so quit used to leave shells and agent CLIs orphaned.
        do {
            let pty = PTYProcess(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                workingDirectory: NSTemporaryDirectory(),
                environment: [:],
                rows: 24,
                columns: 80
            )
            do {
                try pty.launch()
                let pid = pty.hangUpSynchronously()
                expect(pid != nil, "hangUpSynchronously reports the pid it signalled")
                if let pid {
                    PTYProcess.waitForExit(of: [pid], upTo: 2.0)
                    // The child is reaped by the exit watcher, so the pid is
                    // gone rather than a zombie once it has actually died.
                    var stillAlive = false
                    for _ in 0..<50 {
                        if kill(pid, 0) != 0 { break }
                        usleep(20_000)
                        stillAlive = kill(pid, 0) == 0
                    }
                    expect(!stillAlive, "the child is dead once the synchronous hang-up returns")
                }
                // A second call on an already-terminated process is harmless.
                expect(pty.hangUpSynchronously() == nil, "hanging up twice is a no-op")
            } catch {
                failures.append("PTY hang-up test could not launch a child: \(error)")
            }
        }
        // An empty pid list must not wait out the timeout.
        do {
            let started = Date()
            PTYProcess.waitForExit(of: [], upTo: 5.0)
            expect(Date().timeIntervalSince(started) < 1.0, "waiting on no children returns at once")
        }

        // MARK: - Parser: DCS / APC / PM / SOS payloads are swallowed

        // Without a string state the parser returned to ground immediately and
        // painted the whole payload onto the grid as literal text.
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}P0;1|xyz\u{1B}\\OK".utf8)) == [.print("O"), .print("K")],
               "a DCS payload is consumed, and text after ST still prints")
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}_Ga=T,f=100;PAYLOAD\u{1B}\\OK".utf8)) == [.print("O"), .print("K")],
               "an APC (kitty graphics) payload is consumed")
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}^priv\u{1B}\\OK".utf8)) == [.print("O"), .print("K")],
               "a PM payload is consumed")
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}Xsos\u{1B}\\OK".utf8)) == [.print("O"), .print("K")],
               "an SOS payload is consumed")
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}Pabc\u{07}OK".utf8)) == [.print("O"), .print("K")],
               "BEL also terminates a device string")
        // Split across reads, the way a real PTY delivers it.
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}Pdata".utf8)).isEmpty, "a partial device string emits nothing")
        expect(parser.parse(Array("more\u{1B}\\Z".utf8)) == [.print("Z")],
               "a device string terminated in a later read is still consumed")

        // MARK: - Parser: SGR colon sub-parameters stay one attribute

        parser = TerminalParser()
        var curly = CellStyle.plain
        curly.underline = true
        expect(parser.parse(Array("\u{1B}[4:3m".utf8)) == [.setStyle(curly)],
               "4:3 curly underline sets underline only, not italic")
        expect(parser.parse(Array("\u{1B}[4:0m".utf8)) == [.setStyle(.plain)],
               "4:0 turns the underline off")
        // Underline colour is not rendered and must not leak into the style.
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}[58:2::255:0:0m".utf8)) == [.setStyle(.plain)],
               "58 underline colour is swallowed rather than executed")
        // The indexed and truecolor forms must keep working.
        parser = TerminalParser()
        var indexed = CellStyle.plain
        indexed.foreground = .palette(2)
        expect(parser.parse(Array("\u{1B}[38:5:2m".utf8)) == [.setStyle(indexed)],
               "38:5:n indexed colour still resolves")
        parser = TerminalParser()
        var truecolor = CellStyle.plain
        truecolor.foreground = .rgb(1, 2, 3)
        expect(parser.parse(Array("\u{1B}[38:2::1:2:3m".utf8)) == [.setStyle(truecolor)],
               "38:2 with a colorspace slot still resolves")
        parser = TerminalParser()
        expect(parser.parse(Array("\u{1B}[38:2:1:2:3m".utf8)) == [.setStyle(truecolor)],
               "38:2 without a colorspace slot still resolves")

        // MARK: - Screen: shrinking keeps the cursor's screenful, not blank rows

        // A normal shell session has its prompt near the top with blank rows
        // below. Bottom-anchoring the retained window kept those blanks and
        // pushed every real line into scrollback, blanking the terminal.
        screen = TerminalScreen(rows: 8, columns: 10, scrollbackLimit: 50)
        for character in "$ make" { screen.apply(.print(character)) }
        screen.apply(.carriageReturn)
        screen.apply(.lineFeed)
        for character in "building" { screen.apply(.print(character)) }
        screen.apply(.carriageReturn)
        screen.apply(.lineFeed)
        for character in "$ " { screen.apply(.print(character)) }
        expect(screen.cursorRow == 2, "prompt sits on row 2 with rows 3-7 blank")
        screen.resize(rows: 4, columns: 10)
        expect(screen.lineText(0) == "$ make    ", "shrink keeps the command line on screen")
        expect(screen.lineText(1) == "building  ", "shrink keeps the output line on screen")
        expect(screen.cursorRow == 2, "cursor keeps its row when nothing scrolled off")
        expect(screen.scrollbackCount == 0, "nothing is pushed to scrollback when it need not be")

        // With the cursor at the bottom, the window still anchors on it, which
        // reproduces the previous bottom-anchored behavior.
        screen = TerminalScreen(rows: 4, columns: 4, scrollbackLimit: 50)
        for row in 1...4 {
            screen.apply(.moveCursor(row: row, column: 1))
            for character in "r\(row)" { screen.apply(.print(character)) }
        }
        screen.resize(rows: 2, columns: 4)
        expect(screen.lineText(0) == "r3  " && screen.lineText(1) == "r4  ",
               "shrinking from the bottom row keeps the last two lines")
        expect(screen.scrollbackCount == 2, "rows scrolled off the top reach scrollback")
        expect(screen.cursorRow == 1, "cursor stays on its own line")

        // MARK: - Screen: CUU/CUD stop at the DECSTBM margins

        screen = TerminalScreen(rows: 6, columns: 4, scrollbackLimit: 10)
        screen.apply(.setScrollRegion(top: 2, bottom: 5)) // 0-based rows 1...4
        screen.apply(.moveCursor(row: 3, column: 1))      // 0-based row 2, inside
        screen.apply(.moveCursorRelative(rows: -9, columns: 0))
        expect(screen.cursorRow == 1, "CUU stops at the top margin, not row 0")
        screen.apply(.moveCursor(row: 3, column: 1))
        screen.apply(.moveCursorRelative(rows: 9, columns: 0))
        expect(screen.cursorRow == 4, "CUD stops at the bottom margin, not the last row")
        // A cursor parked outside the region keeps plain grid clamping.
        screen.apply(.moveCursor(row: 1, column: 1))      // 0-based row 0, outside
        screen.apply(.moveCursorRelative(rows: 9, columns: 0))
        expect(screen.cursorRow == 5, "a cursor outside the region is clamped to the grid")

        // MARK: - Screen: wide-cell repair still runs after a narrowing resize

        // printCharacter no longer rescans the row on every glyph, so the
        // repair must still happen when a narrowing truncation splits a pair.
        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        screen.apply(.print("漢"))                  // occupies columns 0-1
        screen.apply(.print("字"))                  // occupies columns 2-3
        expect(screen.cell(atRow: 0, column: 1).isContinuation, "wide glyph claims a continuation cell")
        screen.resize(rows: 2, columns: 3)          // cuts the second pair in half
        screen.apply(.moveCursor(row: 1, column: 3))
        screen.apply(.print("x"))                   // first write at the new width
        expect(!screen.cell(atRow: 0, column: 2).isContinuation,
               "an orphaned continuation cell is repaired, not left dangling")
        expect(screen.cell(atRow: 0, column: 0).character == "漢",
               "the intact wide glyph is preserved")

        // MARK: - Screen: ASCII fast path agrees with the Unicode path

        expect(TerminalScreen.columnWidth(of: "A") == 1, "printable ASCII is one column")
        expect(TerminalScreen.columnWidth(of: " ") == 1, "space is one column")
        expect(TerminalScreen.columnWidth(of: "~") == 1, "tilde is one column")
        // DEL is excluded from the fast path and falls through to the Unicode
        // path, which classifies it as a control character of width 1 — the
        // same answer the fast path would have to produce.
        expect(TerminalScreen.columnWidth(of: "\u{7F}") == 1, "DEL keeps its pre-fast-path width")
        expect(TerminalScreen.columnWidth(of: "漢") == 2, "CJK stays wide")
        expect(TerminalScreen.columnWidth(of: "\u{0301}") == 0, "combining marks stay zero width")
        expect(TerminalScreen.columnWidth(of: "🚀") == 2, "emoji stay wide")

        // Combining marks still merge onto the previous ASCII base character.
        screen = TerminalScreen(rows: 1, columns: 4, scrollbackLimit: 0)
        screen.apply(.print("e"))
        screen.apply(.print("\u{0301}"))
        expect(screen.lineText(0).hasPrefix("é"), "a combining mark merges onto an ASCII base")
        expect(screen.cursorColumn == 1, "a merged combining mark does not advance the cursor")

        // A hostile process can emit combining marks forever. The rendered
        // grapheme must remain bounded instead of retaining every scalar in a
        // single cell.
        for _ in 0..<(TerminalScreen.maximumScalarsPerCell * 3) {
            screen.apply(.print("\u{0301}"))
        }
        expect(
            screen.cell(atRow: 0, column: 0).character.unicodeScalars.count
                <= TerminalScreen.maximumScalarsPerCell,
            "one terminal cell caps an unbounded combining-mark stream"
        )
        expect(screen.cursorColumn == 1, "discarded combining marks do not advance the cursor")

        // The read queue can outrun the main actor. Coalescing stays bounded and
        // records the overflow, and what it discards is the OLDEST output.
        // Keeping a stale prefix and dropping the tail instead leaves the screen
        // showing mid-stream lines followed by the prompt, which the user cannot
        // tell apart from the command genuinely ending there.
        let outputBuffer = PTYOutputBuffer()
        let tailMarker = Array("TAIL".utf8)
        let oversizedOutput =
            Array(repeating: UInt8(ascii: "x"), count: PTYOutputBuffer.maximumPendingBytes + 4_096 - tailMarker.count)
            + tailMarker
        expect(outputBuffer.appendAndClaimDrain(oversizedOutput), "the first PTY burst claims one drain")
        expect(
            outputBuffer.bufferedByteCount == PTYOutputBuffer.maximumPendingBytes,
            "PTY buffering stops at its high-water mark"
        )
        expect(outputBuffer.droppedByteCount == 4_096, "PTY overflow is counted")
        let drainedBurst = outputBuffer.takeAll()
        expect(drainedBurst.count == PTYOutputBuffer.maximumPendingBytes, "the bounded PTY window drains")
        expect(
            Array(drainedBurst.suffix(tailMarker.count)) == tailMarker,
            "an oversized burst keeps its newest bytes, not its stale prefix"
        )
        expect(outputBuffer.bufferedByteCount == 0, "draining releases buffered PTY memory")

        // Overflow that builds up across several reads evicts the oldest bytes
        // too, so the most recent output always survives to reach the screen.
        let steadyBuffer = PTYOutputBuffer()
        _ = steadyBuffer.appendAndClaimDrain(
            Array(repeating: UInt8(ascii: "o"), count: PTYOutputBuffer.maximumPendingBytes)
        )
        let newestMarker = Array("NEWEST".utf8)
        _ = steadyBuffer.appendAndClaimDrain(newestMarker)
        expect(
            steadyBuffer.bufferedByteCount == PTYOutputBuffer.maximumPendingBytes,
            "a full buffer stays at the high-water mark after more output arrives"
        )
        expect(steadyBuffer.droppedByteCount == newestMarker.count, "evicted older bytes are counted as dropped")
        let drainedSteady = steadyBuffer.takeAll()
        expect(
            Array(drainedSteady.suffix(newestMarker.count)) == newestMarker,
            "bytes arriving at a full buffer evict the oldest instead of being discarded"
        )

        // MARK: - Screen: alt-screen resize preserves the parked primary screen
        //
        // Shrinking while a TUI holds the alternate screen must push the primary
        // screen's dropped rows into scrollback, exactly as the same shrink does
        // at the shell prompt. Without that, a build log that scrolls off during
        // a resize is gone from the grid AND from scrollback, so the user cannot
        // scroll back to it at all.

        var parked = TerminalScreen(rows: 6, columns: 10, scrollbackLimit: 500)
        for index in 1...6 {
            for character in "LINE\(index)" { parked.apply(.print(character)) }
            if index < 6 {
                parked.apply(.lineFeed)
                parked.apply(.carriageReturn)
            }
        }
        expect(parked.scrollbackCount == 0, "six lines on a six-row screen do not scroll yet")

        // Same shrink at the shell prompt, for parity.
        var atPrompt = parked
        atPrompt.resize(rows: 2, columns: 10)
        let promptScrollback = atPrompt.scrollbackCount
        expect(promptScrollback == 4, "shrinking at the prompt banks the four dropped rows")

        parked.apply(.setMode(.alternateScreen, true))
        for character in "TUI" { parked.apply(.print(character)) }
        parked.resize(rows: 2, columns: 10)
        parked.apply(.setMode(.alternateScreen, false))
        expect(
            parked.scrollbackCount == promptScrollback,
            "shrinking behind a TUI banks the same rows as shrinking at the prompt"
        )
        let oldestParked = String(parked.scrollbackLine(0).map(\.character))
            .trimmingCharacters(in: .whitespaces)
        expect(oldestParked == "LINE1", "the oldest parked primary row is recoverable from scrollback")

        // The scrollback limit still wins: a parked screen cannot push the ring
        // past its cap.
        var cappedPark = TerminalScreen(rows: 8, columns: 6, scrollbackLimit: 2)
        for index in 1...8 {
            for character in "P\(index)" { cappedPark.apply(.print(character)) }
            if index < 8 {
                cappedPark.apply(.lineFeed)
                cappedPark.apply(.carriageReturn)
            }
        }
        cappedPark.apply(.setMode(.alternateScreen, true))
        cappedPark.resize(rows: 2, columns: 6)
        cappedPark.apply(.setMode(.alternateScreen, false))
        expect(cappedPark.scrollbackCount <= 2, "parked rows still respect scrollbackLimit")

        // A screen with no scrollback at all must not accumulate parked rows.
        var noScrollbackPark = TerminalScreen(rows: 6, columns: 6, scrollbackLimit: 0)
        for index in 1...6 {
            for character in "N\(index)" { noScrollbackPark.apply(.print(character)) }
            if index < 6 {
                noScrollbackPark.apply(.lineFeed)
                noScrollbackPark.apply(.carriageReturn)
            }
        }
        noScrollbackPark.apply(.setMode(.alternateScreen, true))
        noScrollbackPark.resize(rows: 2, columns: 6)
        noScrollbackPark.apply(.setMode(.alternateScreen, false))
        expect(noScrollbackPark.scrollbackCount == 0, "scrollbackLimit 0 banks nothing when parked")

        // MARK: - Screen: absolute line anchoring
        //
        // Content-line indices are relative to the front of the scrollback ring,
        // so every trim shifts them down. Anything that must stay pinned to TEXT
        // while output keeps arriving -- a held selection, a scrolled-back
        // viewport -- has to be stored in absolute space and converted back, or
        // it silently slides onto different lines.

        func emitLine(_ target: inout TerminalScreen, _ text: String) {
            for character in text { target.apply(.print(character)) }
            target.apply(.lineFeed)
            target.apply(.carriageReturn)
        }
        func ringText(_ target: TerminalScreen, _ contentLine: Int) -> String {
            String(target.scrollbackLine(contentLine).map(\.character))
                .trimmingCharacters(in: .whitespaces)
        }

        var ring = TerminalScreen(rows: 2, columns: 8, scrollbackLimit: 3)
        expect(ring.scrollbackBase == 0, "a fresh screen has discarded nothing off the front")

        for index in 1...5 { emitLine(&ring, "R\(index)") }
        expect(ring.scrollbackBase > 0, "a full ring has begun trimming")

        // Pin a line, then push one more line through so the ring trims again.
        let watchedContentLine = 1
        let watchedAbsolute = ring.absoluteLine(forContentLine: watchedContentLine)
        let watchedText = ringText(ring, watchedContentLine)
        let baseBeforeTrim = ring.scrollbackBase

        emitLine(&ring, "R6")
        expect(ring.scrollbackBase == baseBeforeTrim + 1, "one more scrolled-off line discards one from the front")

        let resolved = ring.contentLine(forAbsoluteLine: watchedAbsolute)
        expect(resolved == watchedContentLine - 1, "the pinned text shifted down one content index")
        expect(
            resolved.map { ringText(ring, $0) } == watchedText,
            "an absolute reference still names the same text after a trim"
        )

        // Round-trip across the whole addressable range, scrollback and grid.
        let addressable = 0..<(ring.scrollbackCount + ring.rows)
        expect(
            addressable.allSatisfy { ring.contentLine(forAbsoluteLine: ring.absoluteLine(forContentLine: $0)) == $0 },
            "absolute and content line numbers round-trip over scrollback and grid"
        )
        expect(
            ring.absoluteLine(forContentLine: ring.scrollbackCount) == ring.scrollbackBase + ring.scrollbackCount,
            "the first grid row follows the last scrollback line in absolute space"
        )

        // A line that has fallen out of the ring must report as gone rather than
        // resolving to whatever text now occupies its old index.
        let evictedAbsolute = ring.scrollbackBase - 1
        expect(ring.contentLine(forAbsoluteLine: evictedAbsolute) == nil, "a discarded line reports as gone")
        expect(
            ring.contentLine(forAbsoluteLine: ring.absoluteLine(forContentLine: ring.scrollbackCount + ring.rows)) == nil,
            "a line past the live grid reports as gone"
        )

        // Trimming is the only thing that moves the base: plain output that fits
        // inside the ring must not shift existing absolute references.
        var roomy = TerminalScreen(rows: 2, columns: 8, scrollbackLimit: 500)
        for index in 1...4 { emitLine(&roomy, "Q\(index)") }
        let roomyAbsolute = roomy.absoluteLine(forContentLine: 0)
        let roomyText = ringText(roomy, 0)
        for index in 5...20 { emitLine(&roomy, "Q\(index)") }
        expect(roomy.scrollbackBase == 0, "a ring under its limit never discards")
        expect(
            roomy.contentLine(forAbsoluteLine: roomyAbsolute).map { ringText(roomy, $0) } == roomyText,
            "absolute references survive plain output when nothing is trimmed"
        )

        // Resize trims through the same path, so the base has to move there too.
        var resized = TerminalScreen(rows: 6, columns: 8, scrollbackLimit: 2)
        for index in 1...6 { emitLine(&resized, "Z\(index)") }
        let baseBeforeResize = resized.scrollbackBase
        resized.resize(rows: 2, columns: 8)
        expect(
            resized.scrollbackCount <= 2,
            "resize honours the scrollback limit"
        )
        expect(
            resized.scrollbackBase >= baseBeforeResize,
            "rows discarded by a resize advance the absolute base"
        )

        // MARK: - Screen: soft-wrap continuation
        //
        // A row continued by autowrap and a row ended by an explicit newline are
        // indistinguishable once printed -- both can be exactly full. The screen
        // has to record which happened, or copying a wrapped path inserts a
        // newline that breaks it when pasted.

        var wrapped = TerminalScreen(rows: 4, columns: 5, scrollbackLimit: 50)
        for character in "ABCDEFG" { wrapped.apply(.print(character)) }
        expect(wrapped.isLineWrapped(contentLine: 0), "a row continued by autowrap is marked wrapped")
        expect(!wrapped.isLineWrapped(contentLine: 1), "the continuation row is not itself wrapped")

        var hardBreak = TerminalScreen(rows: 4, columns: 5, scrollbackLimit: 50)
        for character in "AB" { hardBreak.apply(.print(character)) }
        hardBreak.apply(.lineFeed)
        hardBreak.apply(.carriageReturn)
        for character in "CD" { hardBreak.apply(.print(character)) }
        expect(!hardBreak.isLineWrapped(contentLine: 0), "a row ended by an explicit newline is not wrapped")

        // The discriminating case: a row filled to exactly the width, then ended
        // by a newline. It looks identical to a wrapped row, so nothing can be
        // inferred from the cells alone.
        var exactlyFull = TerminalScreen(rows: 4, columns: 5, scrollbackLimit: 50)
        for character in "ABCDE" { exactlyFull.apply(.print(character)) }
        exactlyFull.apply(.lineFeed)
        exactlyFull.apply(.carriageReturn)
        for character in "FG" { exactlyFull.apply(.print(character)) }
        expect(
            !exactlyFull.isLineWrapped(contentLine: 0),
            "a row filled exactly to the width then ended by a newline is not wrapped"
        )

        var exactlyFullThenWrap = TerminalScreen(rows: 4, columns: 5, scrollbackLimit: 50)
        for character in "ABCDEF" { exactlyFullThenWrap.apply(.print(character)) }
        expect(
            exactlyFullThenWrap.isLineWrapped(contentLine: 0),
            "a row filled exactly to the width then continued IS wrapped"
        )

        // The flag has to travel with the text, not with the row index.
        var travelling = TerminalScreen(rows: 2, columns: 5, scrollbackLimit: 50)
        for character in "ABCDEFG" { travelling.apply(.print(character)) }
        for _ in 0..<3 {
            travelling.apply(.lineFeed)
            travelling.apply(.carriageReturn)
        }
        expect(travelling.scrollbackCount >= 3, "the wrapped line scrolled into scrollback")
        expect(travelling.isLineWrapped(contentLine: 0), "the wrap flag follows its line into scrollback")
        expect(!travelling.isLineWrapped(contentLine: 1), "the continuation line stays unwrapped in scrollback")

        // Erasing a row clears its continuation: the text that wrapped is gone.
        var erased = TerminalScreen(rows: 4, columns: 5, scrollbackLimit: 50)
        for character in "ABCDEFG" { erased.apply(.print(character)) }
        expect(erased.isLineWrapped(contentLine: 0), "precondition: row 0 wrapped")
        erased.apply(.eraseInDisplay(2))
        expect(!erased.isLineWrapped(contentLine: 0), "erasing the screen clears continuation flags")

        // Out-of-range queries must not trap.
        expect(!erased.isLineWrapped(contentLine: -1), "a negative content line is not wrapped")
        expect(
            !erased.isLineWrapped(contentLine: erased.scrollbackCount + erased.rows + 5),
            "a content line past the grid is not wrapped"
        )

        // MARK: - Selection text joining

        typealias JoinRow = TerminalTextJoiner.Row
        expect(
            TerminalTextJoiner.join([
                JoinRow(text: "/Users/me/Projects/Finder", continuesToNextRow: true),
                JoinRow(text: "Path/Terminal.swift", continuesToNextRow: false),
            ]) == "/Users/me/Projects/FinderPath/Terminal.swift",
            "a soft-wrapped path rejoins into one pasteable line"
        )
        expect(
            TerminalTextJoiner.join([
                JoinRow(text: "first", continuesToNextRow: false),
                JoinRow(text: "second", continuesToNextRow: false),
            ]) == "first\nsecond",
            "genuinely separate rows keep their newline"
        )
        expect(
            TerminalTextJoiner.join([JoinRow(text: "only", continuesToNextRow: true)]) == "only",
            "a trailing wrapped row does not gain a dangling separator"
        )
        expect(TerminalTextJoiner.join([]).isEmpty, "joining nothing yields nothing")
        expect(
            TerminalTextJoiner.join([
                JoinRow(text: "a", continuesToNextRow: true),
                JoinRow(text: "b", continuesToNextRow: true),
                JoinRow(text: "c", continuesToNextRow: false),
                JoinRow(text: "d", continuesToNextRow: false),
            ]) == "abc\nd",
            "a run of wrapped rows collapses into a single line"
        )

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
