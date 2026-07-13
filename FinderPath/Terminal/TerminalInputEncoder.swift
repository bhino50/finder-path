import Foundation

// Translates key events into the byte sequences a PTY expects. Pure logic —
// no AppKit — so encoding rules stay testable with the dependency-free test
// runner. Sequences target TERM=xterm-256color.

enum TerminalInputEncoder {
    enum SpecialKey: Equatable, Sendable {
        case up
        case down
        case left
        case right
        case home
        case end
        case pageUp
        case pageDown
        case forwardDelete
        case escape
        case enter
        case tab
        case backspace
        /// F1-F12; other numbers encode to nothing.
        case function(Int)
    }

    private static let esc: UInt8 = 0x1B
    /// CSI introducer, ESC [.
    private static let csi: [UInt8] = [0x1B, 0x5B]
    /// SS3 introducer, ESC O — used by application cursor mode and F1-F4.
    private static let ss3: [UInt8] = [0x1B, 0x4F]

    static func encode(text: String) -> [UInt8] {
        Array(text.utf8)
    }

    static func encode(specialKey: SpecialKey, applicationCursorKeys: Bool) -> [UInt8] {
        switch specialKey {
        case .up:
            return cursorSequence(final: 0x41, applicationMode: applicationCursorKeys)
        case .down:
            return cursorSequence(final: 0x42, applicationMode: applicationCursorKeys)
        case .right:
            return cursorSequence(final: 0x43, applicationMode: applicationCursorKeys)
        case .left:
            return cursorSequence(final: 0x44, applicationMode: applicationCursorKeys)
        case .home:
            return cursorSequence(final: 0x48, applicationMode: applicationCursorKeys)
        case .end:
            return cursorSequence(final: 0x46, applicationMode: applicationCursorKeys)
        case .pageUp:
            return tildeSequence(code: 5)
        case .pageDown:
            return tildeSequence(code: 6)
        case .forwardDelete:
            return tildeSequence(code: 3)
        case .escape:
            return [esc]
        case .enter:
            return [0x0D]
        case .tab:
            return [0x09]
        case .backspace:
            return [0x7F]
        case .function(let number):
            return functionKeySequence(number)
        }
    }

    /// Control-key combinations with a defined C0 mapping: a-z (either case)
    /// map to 0x01-0x1A, and the classic punctuation set covers 0x1B-0x1F.
    /// Anything else has no control encoding and returns nil.
    static func encodeControl(character: Character) -> [UInt8]? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: // a-z
            return [ascii - 0x60]
        case 0x41...0x5A: // A-Z
            return [ascii - 0x40]
        case 0x5B: // [
            return [0x1B]
        case 0x5C: // backslash
            return [0x1C]
        case 0x5D: // ]
            return [0x1D]
        case 0x5E: // ^
            return [0x1E]
        case 0x5F: // _
            return [0x1F]
        default:
            return nil
        }
    }

    /// Bracketed paste wraps content in ESC[200~ / ESC[201~ and strips every
    /// ESC byte from the pasted text so hostile clipboard content cannot end
    /// the bracket early or inject sequences (paste-injection defense).
    static func encodePaste(_ text: String, bracketed: Bool) -> [UInt8] {
        let content = Array(text.utf8)
        guard bracketed else { return content }
        let sanitized = content.filter { $0 != esc }
        return csi + Array("200~".utf8) + sanitized + csi + Array("201~".utf8)
    }

    // MARK: - Sequence builders

    /// Arrows and home/end share finals; DECCKM switches CSI to SS3.
    private static func cursorSequence(final: UInt8, applicationMode: Bool) -> [UInt8] {
        (applicationMode ? ss3 : csi) + [final]
    }

    private static func tildeSequence(code: Int) -> [UInt8] {
        csi + Array("\(code)~".utf8)
    }

    /// F1-F4 are SS3 P/Q/R/S (VT100 PF keys); F5-F12 use CSI n~ with the
    /// historical xterm gaps (no 16, no 22).
    private static func functionKeySequence(_ number: Int) -> [UInt8] {
        switch number {
        case 1: return ss3 + [0x50]
        case 2: return ss3 + [0x51]
        case 3: return ss3 + [0x52]
        case 4: return ss3 + [0x53]
        case 5: return tildeSequence(code: 15)
        case 6: return tildeSequence(code: 17)
        case 7: return tildeSequence(code: 18)
        case 8: return tildeSequence(code: 19)
        case 9: return tildeSequence(code: 20)
        case 10: return tildeSequence(code: 21)
        case 11: return tildeSequence(code: 23)
        case 12: return tildeSequence(code: 24)
        default: return []
        }
    }
}
