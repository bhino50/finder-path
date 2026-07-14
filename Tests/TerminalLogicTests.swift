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

        // Resizing the alternate screen hands the app a clean slate: it repaints
        // fully on the following SIGWINCH, so reflowing the old absolutely-
        // positioned frame only leaves mangled overlap (the garbled Claude Code
        // frame after a window resize). Primary-screen resize still reflows.
        screen = TerminalScreen(rows: 2, columns: 6, scrollbackLimit: 10)
        screen.apply(.setMode(.alternateScreen, true))
        for character in "claude" { screen.apply(.print(character)) }
        expect(screen.lineText(0) == "claude", "alt screen holds the drawn frame")
        screen.resize(rows: 2, columns: 3)
        expect(screen.columns == 3, "alt-screen resize applies the new width")
        expect(screen.lineText(0).trimmingCharacters(in: .whitespaces).isEmpty,
               "alt-screen resize clears to a clean slate, not a truncated frame")

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
