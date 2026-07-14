import Foundation

// Streaming VT/xterm escape-sequence parser. Feed it raw PTY bytes in any
// chunking; it buffers partial UTF-8 characters and partial escape sequences
// between calls and emits typed TerminalActions. Unknown sequences are
// consumed silently so hostile or exotic output cannot corrupt parser state.

struct TerminalParser {
    private enum State {
        case ground
        case escape
        case escapeCharset
        case csi
        case osc
        case oscEscape
    }

    private static let maxParameterValue = 9999
    private static let maxParameterCount = 16
    private static let maxOSCLength = 2048

    private var state: State = .ground
    private var csiBuffer = ""
    private var oscBuffer: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0

    /// The running SGR style; `setStyle` actions carry the resolved result.
    private var currentStyle = CellStyle.plain

    init() {}

    mutating func parse(_ bytes: [UInt8]) -> [TerminalAction] {
        var actions: [TerminalAction] = []

        for byte in bytes {
            switch state {
            case .ground:
                parseGround(byte, into: &actions)
            case .escape:
                parseEscape(byte, into: &actions)
            case .escapeCharset:
                // ESC ( X or ESC ) X — consume the charset designator.
                state = .ground
            case .csi:
                parseCSI(byte, into: &actions)
            case .osc:
                parseOSC(byte, into: &actions)
            case .oscEscape:
                if byte == UInt8(ascii: "\\") {
                    finishOSC(into: &actions)
                } else {
                    // Not a string terminator; drop the OSC and reprocess.
                    oscBuffer = []
                    state = .ground
                    parseGround(byte, into: &actions)
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
        case 0x00..<0x20, 0x7F:
            break // other C0 controls and DEL are ignored
        case 0x20..<0x7F:
            actions.append(.print(Character(UnicodeScalar(byte))))
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
        let decoded = String(decoding: utf8Buffer, as: UTF8.self)
        utf8Buffer = []
        utf8Expected = 0
        for character in decoded where character != "\u{FFFD}" {
            actions.append(.print(character))
        }
    }

    // MARK: - Escape state

    private mutating func parseEscape(_ byte: UInt8, into actions: inout [TerminalAction]) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            csiBuffer = ""
            state = .csi
        case UInt8(ascii: "]"):
            oscBuffer = []
            state = .osc
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            state = .escapeCharset
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
            // RIS hard reset: leave the alternate screen, restore autowrap and
            // a full-height scroll region, then reset style, clear, and home.
            currentStyle = .plain
            actions.append(.setMode(.alternateScreen, false))
            actions.append(.setMode(.autowrap, true))
            actions.append(.setScrollRegion(top: 1, bottom: 0))
            actions.append(.setStyle(.plain))
            actions.append(.eraseInDisplay(2))
            actions.append(.moveCursor(row: 1, column: 1))
        case UInt8(ascii: "="), UInt8(ascii: ">"):
            break // keypad modes, ignored
        case 0x1B:
            state = .escape
        default:
            break // unknown escape, consumed
        }
    }

    // MARK: - CSI state

    private mutating func parseCSI(_ byte: UInt8, into actions: inout [TerminalAction]) {
        switch byte {
        case 0x30...0x3F: // digits ; : ? > < =
            if csiBuffer.count < 64 {
                csiBuffer.append(Character(UnicodeScalar(byte)))
            }
        case 0x20...0x2F:
            break // intermediates collected but unused
        case 0x40...0x7E:
            let buffer = csiBuffer
            csiBuffer = ""
            state = .ground
            dispatchCSI(final: Character(UnicodeScalar(byte)), buffer: buffer, into: &actions)
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
        guard !trimmed.isEmpty else { return [] }
        let flattened = trimmed.replacingOccurrences(of: ":", with: ";")
        return flattened.split(separator: ";", omittingEmptySubsequences: false).prefix(maxParameterCount * 2).map {
            guard let value = Int($0) else { return nil }
            return min(value, maxParameterValue)
        }
    }

    private mutating func applySGR(_ params: [Int?], into actions: inout [TerminalAction]) {
        var values = params.map { $0 ?? 0 }
        if values.isEmpty { values = [0] }

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
            case 38, 48:
                let isForeground = value == 38
                if index + 1 < values.count, values[index + 1] == 5, index + 2 < values.count {
                    let color = TerminalColor.palette(UInt8(clamping: values[index + 2]))
                    if isForeground { currentStyle.foreground = color } else { currentStyle.background = color }
                    index += 2
                } else if index + 1 < values.count, values[index + 1] == 2, index + 4 < values.count {
                    let color = TerminalColor.rgb(
                        UInt8(clamping: values[index + 2]),
                        UInt8(clamping: values[index + 3]),
                        UInt8(clamping: values[index + 4])
                    )
                    if isForeground { currentStyle.foreground = color } else { currentStyle.background = color }
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
