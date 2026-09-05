import Foundation

// Streaming VT/xterm escape-sequence parser. Feed it raw PTY bytes in any
// chunking; it buffers partial UTF-8 characters and partial escape sequences
// between calls and emits typed TerminalActions. Unknown sequences are
// consumed silently so hostile or exotic output cannot corrupt parser state.

struct TerminalParser {
    /// Which character set a designator selected. Only the DEC Special
    /// Graphics set differs from ASCII in a way this parser has to honour.
    private enum Charset {
        case ascii
        case decSpecialGraphics
    }

    /// VT100 DEC Special Graphics: 0x5F-0x7E map to line drawing and a handful
    /// of symbols. Bytes outside that range are unaffected by the charset.
    private static let decSpecialGraphics: [UInt8: Character] = [
        0x5F: "\u{00A0}", 0x60: "\u{25C6}", 0x61: "\u{2592}", 0x62: "\u{2409}",
        0x63: "\u{240C}", 0x64: "\u{240D}", 0x65: "\u{240A}", 0x66: "\u{00B0}",
        0x67: "\u{00B1}", 0x68: "\u{2424}", 0x69: "\u{240B}", 0x6A: "\u{2518}",
        0x6B: "\u{2510}", 0x6C: "\u{250C}", 0x6D: "\u{2514}", 0x6E: "\u{253C}",
        0x6F: "\u{23BA}", 0x70: "\u{23BB}", 0x71: "\u{2500}", 0x72: "\u{23BC}",
        0x73: "\u{23BD}", 0x74: "\u{251C}", 0x75: "\u{2524}", 0x76: "\u{2534}",
        0x77: "\u{252C}", 0x78: "\u{2502}", 0x79: "\u{2264}", 0x7A: "\u{2265}",
        0x7B: "\u{03C0}", 0x7C: "\u{2260}", 0x7D: "\u{00A3}", 0x7E: "\u{00B7}",
    ]

    private enum State {
        case ground
        case escape
        /// ESC followed by an intermediate byte (0x20-0x2F): runs to a final.
        case escapeIntermediate
        case escapeCharset
        case csi
        case osc
        case oscEscape
        /// DCS / APC / PM / SOS payload: consumed and discarded until ST.
        case deviceString
        case deviceStringEscape
    }

    private nonisolated static let maxParameterValue = 9999
    private static let maxParameterCount = 16
    private static let maxOSCLength = 2048

    private var state: State = .ground
    private var csiBuffer = ""
    /// Unsupported intermediates and oversized parameters invalidate the whole
    /// command. Keep consuming through its final byte without executing a prefix.
    private var csiIgnored = false
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0

    /// The running SGR style; `setStyle` actions carry the resolved result.
    private var currentStyle = CellStyle.plain

    private var g0Charset: Charset = .ascii
    private var g1Charset: Charset = .ascii
    /// True between SO and SI, when G1 rather than G0 is drawn from.
    private var usingG1 = false
    private var pendingCharsetIsG1 = false

    private var activeCharset: Charset { usingG1 ? g1Charset : g0Charset }

    /// The character a printable byte stands for under the active charset.
    private func printable(_ byte: UInt8) -> Character {
        guard activeCharset == .decSpecialGraphics,
              let mapped = Self.decSpecialGraphics[byte] else {
            return Character(UnicodeScalar(byte))
        }
        return mapped
    }

    init() {}

    mutating func parse(_ bytes: [UInt8]) -> [TerminalAction] {
        var actions: [TerminalAction] = []

        for byte in bytes {
            // CAN and SUB cancel any in-flight control sequence or string.
            // Without this, an interrupted OSC/DCS can swallow subsequent output.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                csiBuffer = ""
                csiIgnored = false
                oscBuffer = []
                utf8Buffer = []
                utf8Expected = 0
                continue
            }
            // C0 controls remain executable inside ESC/CSI sequences without
            // ending them. String payloads have separate termination rules.
            if (byte < 0x20 && byte != 0x1B) || byte == 0x7F {
                switch state {
                case .escape, .escapeIntermediate, .escapeCharset, .csi:
                    parseGround(byte, into: &actions)
                    continue
                default:
                    break
                }
            }
            switch state {
            case .ground:
                parseGround(byte, into: &actions)
            case .escape:
                parseEscape(byte, into: &actions)
            case .escapeIntermediate:
                // Further intermediates extend the sequence; anything else is
                // the final byte and completes it without printing.
                if !(0x20...0x2F).contains(byte) {
                    state = byte == 0x1B ? .escape : .ground
                }
            case .escapeCharset:
                if byte == 0x1B {
                    state = .escape
                    continue
                }
                // ESC ( X or ESC ) X — record which charset was designated.
                // The designator used to be consumed and thrown away, which is
                // why line drawing printed as the raw letters.
                let designated: Charset = byte == UInt8(ascii: "0") ? .decSpecialGraphics : .ascii
                if pendingCharsetIsG1 { g1Charset = designated } else { g0Charset = designated }
                state = .ground
            case .csi:
                parseCSI(byte, into: &actions)
            case .osc:
                parseOSC(byte, into: &actions)
            case .deviceString:
                // The payload is discarded, so only the terminator matters.
                if byte == 0x1B {
                    state = .deviceStringEscape
                } else if byte == 0x07 {
                    state = .ground // BEL terminates these strings too
                }
            case .deviceStringEscape:
                if byte == UInt8(ascii: "\\") {
                    state = .ground // ST
                } else {
                    // ESC starts a new command even if the old string never
                    // received ST (for example after an interrupted program).
                    parseEscape(byte, into: &actions)
                }
            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    finishOSC(into: &actions)
                } else {
                    // Not a string terminator; drop the OSC and reprocess.
                    oscBuffer = []
                    parseEscape(byte, into: &actions)
                }
            }
        }

        return actions
    }

    // MARK: - Ground state

    private mutating func parseGround(_ byte: UInt8, into actions: inout [TerminalAction]) {
        if utf8Expected > 0 {
            if byte & 0b1100_0000 == 0b1000_0000 {
                utf8Buffer.append(byte)
                if utf8Buffer.count == utf8Expected {
                    flushUTF8(into: &actions)
                }
                return
            }
            // Invalid continuation: drop the partial sequence, reprocess byte.
            utf8Buffer = []
            utf8Expected = 0
        }

        switch byte {
        case 0x1B:
            state = .escape
        case 0x0A, 0x0B, 0x0C:
            actions.append(.lineFeed)
        case 0x0D:
            actions.append(.carriageReturn)
        case 0x08:
            actions.append(.backspace)
        case 0x09:
            actions.append(.tab)
        case 0x07:
            actions.append(.bell)
        case 0x0E:
            // SO — shift out to G1, the other route ncurses takes into the
            // line-drawing charset.
            usingG1 = true
        case 0x0F:
            usingG1 = false // SI — shift back in to G0
        case 0x00..<0x20, 0x7F:
            break // other C0 controls and DEL are ignored
        case 0x20..<0x7F:
            actions.append(.print(printable(byte)))
        default:
            // Leading byte of a multi-byte UTF-8 sequence.
            let expected: Int
            if byte & 0b1110_0000 == 0b1100_0000 {
                expected = 2
            } else if byte & 0b1111_0000 == 0b1110_0000 {
                expected = 3
            } else if byte & 0b1111_1000 == 0b1111_0000 {
                expected = 4
            } else {
                return // stray continuation byte, drop it
            }
            utf8Buffer = [byte]
            utf8Expected = expected
        }
    }

    private mutating func flushUTF8(into actions: inout [TerminalAction]) {
        // A lenient decode turns every malformed sequence into U+FFFD, which
        // made a genuine U+FFFD from the child indistinguishable from garbage
        // and dropped it. Validate strictly instead: malformed bytes are
        // discarded, and a real replacement character prints like any glyph.
        let decoded = String(bytes: utf8Buffer, encoding: .utf8)
        utf8Buffer = []
        utf8Expected = 0
        guard let decoded else { return }
        for character in decoded {
            actions.append(.print(character))
        }
    }

    // MARK: - Escape state

    private mutating func parseEscape(_ byte: UInt8, into actions: inout [TerminalAction]) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            csiBuffer = ""
            csiIgnored = false
            state = .csi
        case UInt8(ascii: "]"):
            oscBuffer = []
            state = .osc
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            pendingCharsetIsG1 = byte == UInt8(ascii: ")")
            state = .escapeCharset
        case UInt8(ascii: "P"),   // DCS - e.g. terminfo queries, sixel
             UInt8(ascii: "_"),   // APC - e.g. the kitty graphics protocol
             UInt8(ascii: "^"),   // PM
             UInt8(ascii: "X"):   // SOS
            // These introduce a string payload that runs until ST. Without a
            // state to absorb it the parser returned to ground immediately and
            // painted the entire payload onto the grid as literal text.
            state = .deviceString
        case UInt8(ascii: "M"):
            actions.append(.reverseIndex)
        case UInt8(ascii: "D"):
            actions.append(.index)
        case UInt8(ascii: "E"):
            actions.append(.nextLine)
        case UInt8(ascii: "7"):
            actions.append(.saveCursor)
        case UInt8(ascii: "8"):
            actions.append(.restoreCursor)
        case UInt8(ascii: "c"):
            // RIS hard reset is one atomic screen action so saved cursor,
            // alternate-buffer, title, and mode state cannot leak through.
            currentStyle = .plain
            // A TUI killed mid-draw leaves the graphics charset selected, and
            // every letter then renders as line drawing. RIS is exactly what
            // `reset` sends to fix that, so it has to clear the charset state.
            g0Charset = .ascii
            g1Charset = .ascii
            usingG1 = false
            actions.append(.hardReset)
        case UInt8(ascii: "="), UInt8(ascii: ">"):
            break // keypad modes, ignored
        case 0x1B:
            state = .escape
        case 0x20...0x2F:
            // Intermediate byte (ESC # 8 DECALN, ESC % G, ESC sp F). The
            // sequence continues to a final byte; returning to ground here
            // printed that final byte onto the grid.
            state = .escapeIntermediate
        default:
            break // unknown escape, consumed
        }
    }

    // MARK: - CSI state

    private mutating func parseCSI(_ byte: UInt8, into actions: inout [TerminalAction]) {
        switch byte {
        case 0x30...0x3F: // digits ; : ? > < =
            if !csiIgnored, csiBuffer.count < 64 {
                csiBuffer.append(Character(UnicodeScalar(byte)))
            } else {
                csiIgnored = true
            }
        case 0x20...0x2F:
            csiIgnored = true // no CSI commands with intermediates are implemented
        case 0x40...0x7E:
            let buffer = csiBuffer
            csiBuffer = ""
            state = .ground
            if !csiIgnored {
                dispatchCSI(final: Character(UnicodeScalar(byte)), buffer: buffer, into: &actions)
            }
            csiIgnored = false
        case 0x1B:
            csiBuffer = ""
            state = .escape
        default:
            break // C0 controls inside CSI are ignored
        }
    }

    private static func parameters(from buffer: String) -> [Int?] {
        let trimmed = buffer.drop(while: { "?><=".contains($0) })
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ";", omittingEmptySubsequences: false).prefix(maxParameterCount).map {
            guard let value = Int($0) else { return nil }
            return min(value, maxParameterValue)
        }
    }

    private mutating func dispatchCSI(final: Character, buffer: String, into actions: inout [TerminalAction]) {
        let isPrivate = buffer.hasPrefix("?")
        // `>`, `<` and `=` introduce vendor-private sequences (xterm's
        // modifyOtherKeys `CSI > 4;1 m`, kitty's keyboard protocol
        // `CSI > 1 u`, tertiary DA). None are implemented, and dispatching
        // them by their ANSI final byte applied real SGR attributes or
        // teleported the cursor mid-draw.
        if let marker = buffer.first, "><=".contains(marker) { return }
        // DEC-private save/restore, erase, and query commands are distinct from
        // ANSI commands with the same final byte. Only private h/l is supported.
        if isPrivate, final != "h", final != "l" { return }
        let parameterBody = isPrivate ? buffer.dropFirst() : buffer[...]
        guard parameterBody.utf8.allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B || $0 == 0x3A }),
              final == "m" || !parameterBody.contains(":") else { return }
        let params = Self.parameters(from: buffer)
        func param(_ index: Int, default defaultValue: Int) -> Int {
            guard index < params.count, let value = params[index] else { return defaultValue }
            return value
        }
        func count(_ index: Int = 0) -> Int { max(param(index, default: 1), 1) }

        switch final {
        case "A":
            actions.append(.moveCursorRelative(rows: -count(), columns: 0))
        case "B", "e":
            actions.append(.moveCursorRelative(rows: count(), columns: 0))
        case "C", "a":
            actions.append(.moveCursorRelative(rows: 0, columns: count()))
        case "D":
            actions.append(.moveCursorRelative(rows: 0, columns: -count()))
        case "E":
            actions.append(.moveCursorRelative(rows: count(), columns: 0))
            actions.append(.moveCursor(row: nil, column: 1))
        case "F":
            actions.append(.moveCursorRelative(rows: -count(), columns: 0))
            actions.append(.moveCursor(row: nil, column: 1))
        case "G", "`":
            actions.append(.moveCursor(row: nil, column: count()))
        case "d":
            actions.append(.moveCursor(row: count(), column: nil))
        case "H", "f":
            actions.append(.moveCursor(row: count(0), column: count(1)))
        case "J":
            actions.append(.eraseInDisplay(param(0, default: 0)))
        case "K":
            actions.append(.eraseInLine(param(0, default: 0)))
        case "L":
            actions.append(.insertLines(count()))
        case "M":
            actions.append(.deleteLines(count()))
        case "@":
            actions.append(.insertCharacters(count()))
        case "P":
            actions.append(.deleteCharacters(count()))
        case "X":
            actions.append(.eraseCharacters(count()))
        case "S":
            actions.append(.scrollUp(count()))
        case "T":
            actions.append(.scrollDown(count()))
        case "r":
            // Bottom 0 is a sentinel the screen resolves to its last row.
            actions.append(.setScrollRegion(top: count(0), bottom: param(1, default: 0)))
        case "s":
            actions.append(.saveCursor)
        case "u":
            actions.append(.restoreCursor)
        case "n":
            actions.append(.reportDeviceStatus(param(0, default: 0)))
        case "m":
            applySGR(Self.sgrParameters(from: buffer), into: &actions)
        case "h", "l":
            guard isPrivate else { break }
            let enabled = final == "h"
            for parameter in params {
                guard let mode = Self.privateMode(parameter) else { continue }
                actions.append(.setMode(mode, enabled))
            }
        default:
            break // DA, window ops, and other queries are consumed
        }
    }

    private static func privateMode(_ parameter: Int?) -> TerminalMode? {
        switch parameter {
        case 1: return .applicationCursorKeys
        case 7: return .autowrap
        case 25: return .cursorVisible
        case 47, 1047, 1049: return .alternateScreen
        case 2004: return .bracketedPaste
        default: return nil
        }
    }

    // MARK: - SGR

    /// SGR sub-parameters may be colon-delimited (ITU-T), e.g. `38:5:n` or
    /// `38:2:r:g:b`. Treat ':' like ';' so extended-color values are not
    /// collapsed into one non-numeric token that would reset all attributes.
    private static func sgrParameters(from buffer: String) -> [Int?] {
        let trimmed = buffer.drop(while: { "?><=".contains($0) })
        guard !trimmed.isEmpty else { return [0] }
        var values: [Int?] = []
        for parameter in trimmed.split(separator: ";", omittingEmptySubsequences: false) {
            let subparameters = parameter.split(separator: ":", omittingEmptySubsequences: false)
            if subparameters.count == 1 {
                values.append(clampedParameter(subparameters[0]))
            } else {
                values.append(contentsOf: expandedSubparameters(subparameters))
            }
            if values.count >= maxParameterCount * 2 { break }
        }
        return Array(values.prefix(maxParameterCount * 2))
    }

    /// A colon group is ONE parameter carrying sub-parameters, not several
    /// independent parameters. Only the extended-color codes consume their
    /// sub-parameters as values; elsewhere a sub-parameter selects a variant of
    /// the same attribute. Emitting them all as top-level codes executed them
    /// as unrelated attributes — `4:3` (curly underline) turned into underline
    /// plus SGR 3 italic, and `58:2:...` (underline color) ran its arguments as
    /// faint and colour codes.
    private static func expandedSubparameters<S: StringProtocol>(_ parts: [S]) -> [Int?] {
        guard let head = clampedParameter(parts[0]) else {
            // A malformed empty head behaves like an empty parameter: reset.
            return [nil]
        }
        switch head {
        case 38, 48:
            if parts.count >= 6, parts[1] == "2" {
                // ISO-8613-6 truecolor permits a colorspace-id slot:
                // 38:2:<colorspace>:r:g:b. xterm commonly leaves it empty.
                // The renderer supports sRGB, so ignore that slot deliberately.
                var expanded: [Int?] = [head, clampedParameter(parts[1])]
                expanded.append(contentsOf: parts[3...5].map(clampedParameter))
                return expanded
            }
            // 38:5:n and 38:2:r:g:b already line up with what applySGR expects.
            return parts.map(clampedParameter)
        case 58, 59:
            // Underline colour is not rendered. Swallow the whole group so its
            // arguments cannot be executed as unrelated attributes.
            return []
        case 4:
            // 4:0 turns the underline off; every other style turns it on.
            return [clampedParameter(parts[1]) == 0 ? 24 : 4]
        default:
            // A sub-parameterised variant of an attribute we do not model.
            return [head]
        }
    }

    private nonisolated static func clampedParameter<S: StringProtocol>(_ value: S) -> Int? {
        guard let parsed = Int(value) else { return nil }
        return min(parsed, maxParameterValue)
    }

    private mutating func applySGR(_ params: [Int?], into actions: inout [TerminalAction]) {
        // An empty CSI m explicitly supplies reset above. An empty list here
        // means only unsupported colon attributes were consumed; retain style.
        let values = params.map { $0 ?? 0 }

        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0: currentStyle = .plain
            case 1: currentStyle.bold = true
            case 2: currentStyle.faint = true
            case 3: currentStyle.italic = true
            case 4: currentStyle.underline = true
            case 7: currentStyle.inverse = true
            case 22: currentStyle.bold = false; currentStyle.faint = false
            case 23: currentStyle.italic = false
            case 24: currentStyle.underline = false
            case 27: currentStyle.inverse = false
            case 30...37: currentStyle.foreground = .ansi(UInt8(value - 30))
            case 39: currentStyle.foreground = .defaultForeground
            case 40...47: currentStyle.background = .ansi(UInt8(value - 40))
            case 49: currentStyle.background = .defaultBackground
            case 90...97: currentStyle.foreground = .ansi(UInt8(value - 90 + 8))
            case 100...107: currentStyle.background = .ansi(UInt8(value - 100 + 8))
            case 38, 48, 58:
                let isForeground = value == 38
                let isBackground = value == 48
                if index + 1 < values.count, values[index + 1] == 5, index + 2 < values.count {
                    let color = TerminalColor.palette(UInt8(clamping: values[index + 2]))
                    if isForeground { currentStyle.foreground = color }
                    if isBackground { currentStyle.background = color }
                    index += 2
                } else if index + 1 < values.count, values[index + 1] == 2, index + 4 < values.count {
                    let color = TerminalColor.rgb(
                        UInt8(clamping: values[index + 2]),
                        UInt8(clamping: values[index + 3]),
                        UInt8(clamping: values[index + 4])
                    )
                    if isForeground { currentStyle.foreground = color }
                    if isBackground { currentStyle.background = color }
                    index += 4
                } else {
                    index = values.count // malformed extended color, stop
                }
            default:
                break // unsupported SGR attribute, ignored
            }
            index += 1
        }

        actions.append(.setStyle(currentStyle))
    }

    // MARK: - OSC state

    private mutating func parseOSC(_ byte: UInt8, into actions: inout [TerminalAction]) {
        switch byte {
        case 0x07:
            finishOSC(into: &actions)
        case 0x1B:
            state = .oscEscape
        default:
            if oscBuffer.count < Self.maxOSCLength {
                oscBuffer.append(byte)
            }
        }
    }

    private mutating func finishOSC(into actions: inout [TerminalAction]) {
        // Decode the OSC payload as UTF-8; appending raw bytes as scalars would
        // mangle multi-byte titles (e.g. "✳ Claude Code" -> "â³ Claude Code").
        let content = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer = []
        state = .ground

        let parts = content.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first.flatMap({ Int($0) }) else { return }
        if code == 0 || code == 2 {
            actions.append(.setTitle(parts.count > 1 ? String(parts[1]) : ""))
        }
        // Other OSC codes (clipboard, colors, hyperlinks) are ignored.
    }
}
