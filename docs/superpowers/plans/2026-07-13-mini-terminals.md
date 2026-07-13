# Mini Terminals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed homegrown cmux-style terminal sessions in FinderPath's menu bar — stored, background-running, restored across restarts.

**Architecture:** A dependency-free terminal emulator split into pure-logic units (parser, screen, input encoder — all unit-tested) and thin AppKit layers (PTY process, CoreText grid view, popover panel). Sessions are owned by a store that persists metadata JSON and survives popup close.

**Tech Stack:** Swift 5.9+, AppKit, CoreText, POSIX PTY APIs (`openpty`, `posix_spawn`). No third-party code. Built by `script/run_no_xcode.sh` (swiftc) and tested by `script/test_logic.sh`.

## Global Constraints

- macOS 13+ deployment target, `$(uname -m)-apple-macos13.0`
- No external dependencies; no SPM; sources compiled by glob in `run_no_xcode.sh`
- Files 200–400 lines typical, 800 hard max
- No emojis in code or docs; conventional commits
- Scrollback contents never written to disk
- Spec: `docs/superpowers/specs/2026-07-13-mini-terminals-design.md`

---

### Task 1: Terminal core types + build plumbing

**Files:**
- Create: `FinderPath/Terminal/TerminalTypes.swift`
- Modify: `script/run_no_xcode.sh` (SRCS glob)
- Modify: `script/test_logic.sh` (second test binary)
- Create: `Tests/TerminalLogicTests.swift` (skeleton `@main` with `expect` helper, one trivial type assertion)

**Interfaces (Produces):**
```swift
enum TerminalColor: Equatable { case defaultForeground, defaultBackground, ansi(UInt8), palette(UInt8), rgb(UInt8, UInt8, UInt8) }
struct CellStyle: Equatable { var foreground/background: TerminalColor; var bold, faint, italic, underline, inverse: Bool; static let plain: CellStyle }
struct TerminalCell: Equatable { var character: Character; var style: CellStyle; static let blank: TerminalCell }
enum TerminalAction: Equatable {
    case print(Character), lineFeed, carriageReturn, backspace, tab, bell
    case moveCursor(row: Int?, column: Int?)          // 1-based absolutes from CUP/HVP/CHA/VPA
    case moveCursorRelative(rows: Int, columns: Int)  // CUU/CUD/CUF/CUB
    case setStyle(CellStyle)                          // resolved SGR
    case eraseInDisplay(Int), eraseInLine(Int)        // ED/EL modes 0,1,2
    case insertLines(Int), deleteLines(Int), insertCharacters(Int), deleteCharacters(Int), eraseCharacters(Int)
    case setScrollRegion(top: Int, bottom: Int)       // 1-based DECSTBM
    case scrollUp(Int), scrollDown(Int)
    case saveCursor, restoreCursor
    case setMode(TerminalMode, Bool)                  // DEC private + bracketedPaste
    case setTitle(String)
    case reverseIndex, index, nextLine
    case reportDeviceStatus(Int)                      // DSR 5/6 (reply handled by session)
}
enum TerminalMode: Equatable { case alternateScreen, autowrap, bracketedPaste, cursorVisible, applicationCursorKeys }
```

- [ ] Step 1: Write `TerminalTypes.swift` with the types above (SGR resolution lives in the parser task).
- [ ] Step 2: `run_no_xcode.sh`: change `SRCS=("$SRC_DIR"/*.swift)` to also include `"$SRC_DIR"/Terminal/*.swift`.
- [ ] Step 3: `test_logic.sh`: add a second compile+run block building `FinderPath/Terminal/*.swift` logic files with `Tests/TerminalLogicTests.swift` into `FinderPathTerminalTests`.
- [ ] Step 4: Run `./script/test_logic.sh` → both binaries pass. Run `./script/run_no_xcode.sh build` → app still builds.
- [ ] Step 5: Commit `feat: add terminal core types and test plumbing`.

### Task 2: TerminalParser (bytes → actions)

**Files:**
- Create: `FinderPath/Terminal/TerminalParser.swift`
- Test: `Tests/TerminalLogicTests.swift`

**Interfaces:**
- Consumes: `TerminalAction`, `CellStyle`, `TerminalMode` from Task 1.
- Produces: `struct TerminalParser { init(); mutating func parse(_ bytes: [UInt8]) -> [TerminalAction] }` — stateful across calls (partial UTF-8 and partial escape sequences buffered between reads). Tracks current SGR style internally.

State machine: `.ground`, `.escape`, `.csi(params/intermediate/private)`, `.osc(buffer)`, plus UTF-8 continuation buffering. Unknown CSI finals and OSC codes are consumed silently. ESC ( / ) charset selectors consumed. CSI params cap at 16 entries, values cap at 9999 (defense against hostile output).

Representative tests (repo `expect` style):
```swift
var p = TerminalParser()
expect(p.parse(Array("hi".utf8)) == [.print("h"), .print("i")], "plain text prints")
expect(p.parse([0x1B, 0x5B, 0x33, 0x3B, 0x37, 0x48]) == [.moveCursor(row: 3, column: 7)], "CUP moves cursor")
expect(p.parse([0x1B, 0x5B]).isEmpty && p.parse([0x41]) == [.moveCursorRelative(rows: -1, columns: 0)], "split CSI across reads")
// SGR: 31 → red fg; 38;2;10;20;30 → rgb; 38;5;196 → palette; 0 resets
// ED/EL params 0/1/2; DECSTBM; ?1049h/l alt screen; ?2004h/l bracketed paste; ?1h/l DECCKM; ?25h/l cursor
// OSC 0;title BEL and OSC 2;title ST set title; unknown OSC ignored
// 4-byte emoji split across two parse() calls prints one Character
```

- [ ] Step 1: Write failing tests in `Tests/TerminalLogicTests.swift`.
- [ ] Step 2: Run `./script/test_logic.sh` → FAIL (parser type missing).
- [ ] Step 3: Implement `TerminalParser.swift`.
- [ ] Step 4: Run `./script/test_logic.sh` → PASS.
- [ ] Step 5: Commit `feat: add terminal escape sequence parser`.

### Task 3: TerminalScreen (grid model)

**Files:**
- Create: `FinderPath/Terminal/TerminalScreen.swift`
- Test: `Tests/TerminalLogicTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
```swift
struct TerminalScreen {
    init(rows: Int, columns: Int, scrollbackLimit: Int = 2000)
    private(set) var rows: Int; private(set) var columns: Int
    private(set) var cursorRow: Int; private(set) var cursorColumn: Int   // 0-based
    private(set) var cursorVisible: Bool
    private(set) var usingAlternateScreen: Bool
    private(set) var bracketedPaste: Bool
    private(set) var applicationCursorKeys: Bool
    private(set) var title: String
    var scrollbackCount: Int { get }
    func cell(atRow: Int, column: Int) -> TerminalCell        // visible grid
    func scrollbackLine(_ index: Int) -> [TerminalCell]
    mutating func apply(_ action: TerminalAction)
    mutating func resize(rows: Int, columns: Int)             // pad/truncate, no reflow
    func lineText(_ row: Int) -> String                       // test/debug helper
}
```

Semantics locked here: autowrap with deferred wrap (printing at last column sets pending-wrap; next print wraps), LF scrolls within DECSTBM region, lines scrolled off a full-screen region on the primary screen push into the scrollback ring, alternate screen has no scrollback, ED 2 clears grid, cursor clamped on resize, `.setStyle` becomes the brush for subsequent prints and erases fill with the current background.

Representative tests: print+wrap at right edge, deferred wrap, LF at bottom pushes top line to scrollback, DECSTBM 2;5 confines scrolling, alt-screen switch preserves and restores primary content and cursor, insert/deleteLines within region, eraseInLine 0/1/2, resize wider pads and narrower truncates, SGR style captured into printed cells.

- [ ] Step 1: Write failing tests.
- [ ] Step 2: Run `./script/test_logic.sh` → FAIL.
- [ ] Step 3: Implement `TerminalScreen.swift`.
- [ ] Step 4: Run `./script/test_logic.sh` → PASS.
- [ ] Step 5: Commit `feat: add terminal screen grid model`.

### Task 4: TerminalInputEncoder (keys → bytes)

**Files:**
- Create: `FinderPath/Terminal/TerminalInputEncoder.swift`
- Test: `Tests/TerminalLogicTests.swift`

**Interfaces:**
- Produces:
```swift
enum TerminalInputEncoder {
    enum SpecialKey { case up, down, left, right, home, end, pageUp, pageDown, forwardDelete, escape, enter, tab, backspace, function(Int) }
    static func encode(text: String) -> [UInt8]
    static func encode(specialKey: SpecialKey, applicationCursorKeys: Bool) -> [UInt8]
    static func encodeControl(character: Character) -> [UInt8]?       // ctrl-a..z, [, \, ], ^, _
    static func encodePaste(_ text: String, bracketed: Bool) -> [UInt8]
}
```

Arrows: CSI A/B/C/D normally, SS3 A/B/C/D in application-cursor mode. Backspace = 0x7F. Bracketed paste wraps in ESC[200~ / ESC[201~ and strips ESC (0x1B) bytes from the pasted text (paste-injection defense).

- [ ] Step 1: Write failing tests (arrows in both modes, ctrl-c = 0x03, bracketed paste wrapping + ESC stripping, F1–F4).
- [ ] Step 2: Run `./script/test_logic.sh` → FAIL.
- [ ] Step 3: Implement.
- [ ] Step 4: Run → PASS.
- [ ] Step 5: Commit `feat: add terminal input encoder`.

### Task 5: PTYProcess

**Files:**
- Create: `FinderPath/Terminal/PTYProcess.swift`
- Test: `Tests/TerminalLogicTests.swift` (real PTY round-trip)

**Interfaces:**
- Produces:
```swift
final class PTYProcess {
    struct LaunchError: Error { let message: String }
    init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String], rows: Int, columns: Int)
    var onOutput: (([UInt8]) -> Void)?          // fires on a background queue
    var onExit: ((Int32) -> Void)?
    func launch() throws
    func write(_ bytes: [UInt8])
    func resize(rows: Int, columns: Int)
    func terminate()                              // SIGHUP, SIGKILL after grace
    private(set) var isRunning: Bool
    static func defaultShell() -> String          // SHELL env → getpwuid → /bin/zsh
}
```

Implementation notes: `openpty()` for the pair; `posix_spawn` with file actions duping the replica fd to 0/1/2, `POSIX_SPAWN_SETSID`, and `posix_spawn_file_actions_addchdir_np` for the working directory; parent closes the replica; `DispatchSourceRead` on the primary fd; `TIOCSWINSZ` before spawn and on resize; env gets `TERM=xterm-256color` and UTF-8 `LANG`. Shell launched with `-l` (login) arg0 convention.

Test (real, hermetic): spawn `/bin/sh -c 'printf ready'`, expect collected output contains "ready" and exit callback fires with status 0 within a 5s timeout.

- [ ] Step 1: Write failing PTY round-trip test.
- [ ] Step 2: Run `./script/test_logic.sh` → FAIL.
- [ ] Step 3: Implement `PTYProcess.swift`.
- [ ] Step 4: Run → PASS.
- [ ] Step 5: Commit `feat: add PTY process management`.

### Task 6: TerminalSession + TerminalSessionStore

**Files:**
- Create: `FinderPath/Terminal/TerminalSession.swift`
- Create: `FinderPath/Terminal/TerminalSessionStore.swift`
- Test: `Tests/TerminalLogicTests.swift` (metadata codec round-trip)

**Interfaces:**
- Consumes: PTYProcess, TerminalParser, TerminalScreen, TerminalInputEncoder.
- Produces:
```swift
@MainActor final class TerminalSession: Identifiable {
    let id: UUID
    var name: String
    var workingDirectory: String
    enum Status: Equatable { case notStarted, running, exited(Int32), failed(String) }
    private(set) var status: Status
    private(set) var screen: TerminalScreen
    var onScreenUpdate: (() -> Void)?
    var onStatusChange: (() -> Void)?
    func start()                                    // idempotent lazy spawn
    func restart()
    func send(text: String)
    func send(special: TerminalInputEncoder.SpecialKey)
    func paste(_ text: String)
    func resize(rows: Int, columns: Int)
    func terminate()
}

struct TerminalSessionMetadata: Codable, Equatable { let id: UUID; var name: String; var workingDirectory: String }

@MainActor final class TerminalSessionStore {
    static let shared = TerminalSessionStore()
    private(set) var sessions: [TerminalSession]
    var onChange: (() -> Void)?
    func newSession(name: String?, workingDirectory: String) -> TerminalSession   // auto-name "Terminal N"
    func remove(_ session: TerminalSession)                                        // terminate + unpersist
    func loadPersistedSessions()                                                   // creates .notStarted sessions
    func persist()
    func terminateAll()
    static func decodeMetadata(_ data: Data) -> [TerminalSessionMetadata]          // pure, tested
    static func encodeMetadata(_ list: [TerminalSessionMetadata]) -> Data          // pure, tested
}
```

Persistence: `~/Library/Application Support/FinderPath/terminal-sessions.json`, array of `{"id": "...uuid...", "name": "Terminal 1", "workingDirectory": "/Users/x"}`. Corrupt file → empty list, no crash. PTY output hops to the main actor before mutating the screen. `reportDeviceStatus(6)` replies with `ESC[<row>;<col>R` via the PTY.

- [ ] Step 1: Write failing codec tests (round-trip; corrupt data → empty).
- [ ] Step 2: Run `./script/test_logic.sh` → FAIL.
- [ ] Step 3: Implement both files.
- [ ] Step 4: Run → PASS.
- [ ] Step 5: Commit `feat: add terminal sessions and persistent store`.

### Task 7: TerminalView (CoreText grid rendering + keyboard)

**Files:**
- Create: `FinderPath/Terminal/TerminalView.swift`

**Interfaces:**
- Consumes: TerminalSession (screen snapshots, send/paste/resize).
- Produces: `final class TerminalView: NSView` — `var session: TerminalSession?`, `func focusTerminal()`.

Behavior: first responder keyboard handling routed through `TerminalInputEncoder` (⌘C copy selection, ⌘V paste, arrows/ctrl keys/escape); scroll wheel adjusts a scrollback offset (keyboard input snaps back to live); mouse drag selects cells; block cursor drawn as inverse cell; grid drawn per-row with CTLine; cell metrics from the monospaced font (width = advance of "M", height = ascent+descent+leading); redraw coalesced with a dirty flag + 16 ms timer only while dirty; `layout` recomputes rows/columns and calls `session.resize`. Exited/failed sessions draw a status bar row with exit code; the panel offers Restart.

- [ ] Step 1: Implement `TerminalView.swift`.
- [ ] Step 2: `./script/run_no_xcode.sh build` → builds clean.
- [ ] Step 3: Commit `feat: add CoreText terminal view`.

### Task 8: TerminalPanelController (popover + tabs + pin)

**Files:**
- Create: `FinderPath/Terminal/TerminalPanelController.swift`

**Interfaces:**
- Consumes: TerminalSessionStore, TerminalView.
- Produces:
```swift
@MainActor final class TerminalPanelController: NSObject {
    init(store: TerminalSessionStore, newSessionDirectory: @escaping () -> String)
    func toggle(relativeTo statusButton: NSStatusBarButton)
    func show(session: TerminalSession, relativeTo statusButton: NSStatusBarButton)
    private(set) var isPinned: Bool
}
```

Content: top bar with session tabs (name + running dot, close button), "+" button (new session in current Finder folder via `newSessionDirectory`), Restart button when the active session exited, pin button; `TerminalView` below. Popover `behavior = .transient`, size persisted. Pin moves the content into a floating `NSPanel` (`.utilityWindow` style, `level = .floating`, `hidesOnDeactivate = false`, resizable, `setFrameAutosaveName("TerminalPanel")`); unpin returns to popover mode. Closing never terminates sessions.

- [ ] Step 1: Implement `TerminalPanelController.swift`.
- [ ] Step 2: `./script/run_no_xcode.sh build` → builds clean.
- [ ] Step 3: Commit `feat: add terminal panel with tabs and pinning`.

### Task 9: Menu + preferences + settings integration

**Files:**
- Modify: `FinderPath/StatusItem.swift` (Terminals menu section; right-click routes to panel)
- Modify: `FinderPath/Preferences.swift` (new keys)
- Modify: `FinderPath/SettingsUI.swift` (Terminals settings group)
- Modify: `FinderPath/FinderPathApp.swift` (store load on launch, terminate on quit)

**Details:**
- Preferences: `showTerminalsSection` (default true), `terminalFontSize` (12), `terminalScrollbackLimit` (2000), `terminalShellOverride` ("" = login shell), `rightClickOpensTerminals` (true).
- StatusItem: in `statusItemClicked`, `NSApp.currentEvent?.type == .rightMouseUp` + preference → `terminalPanel.toggle(relativeTo:)` instead of the menu. Menu gains a Terminals section after the launchers: one item per stored session (dot prefix when running, tooltip = cwd) opening the panel focused on it, "New Terminal Here" (uses `state.currentPath` when copyable, else home), "Show Terminals".
- Settings UI: new "Terminals" group following existing SettingsUI control patterns.
- App lifecycle: `loadPersistedSessions()` at launch; `terminateAll()` in `applicationWillTerminate`.

- [ ] Step 1: Implement all four modifications.
- [ ] Step 2: `./script/run_no_xcode.sh build` and `./script/test_logic.sh` → pass.
- [ ] Step 3: Commit `feat: integrate terminals into menu, settings, and lifecycle`.

### Task 10: Xcode project registration, docs, verify

**Files:**
- Modify: `FinderPath.xcodeproj/project.pbxproj` (Terminal group + sources build phase)
- Modify: `README.md` (Features + Settings bullets)

- [ ] Step 1: Register the eight Terminal files in the pbxproj (group + file refs + build files).
- [ ] Step 2: Update README features list.
- [ ] Step 3: Run `./script/test_logic.sh` → PASS; `./script/run_no_xcode.sh verify` → app launches and stays running.
- [ ] Step 4: Commit `feat: register terminal sources and document mini terminals`.

## Self-Review Notes

- Spec coverage: emulator scope (Tasks 2–3), input (4), PTY (5), sessions/persistence (6), rendering (7), combo UI (8), menu/right-click/settings/lifecycle (9), build/docs (10). Error handling distributed: spawn failure (5/6), exit row + restart (7/8), corrupt JSON (6).
- No placeholder steps; interface names checked consistent across tasks (`TerminalAction`, `CellStyle`, `apply(_:)`, `SpecialKey`, `Status`, `decodeMetadata`).
- DSR reply path assigned to the session (owns PTY writes).
