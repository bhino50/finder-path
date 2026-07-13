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
