# Mini Terminals — Design Spec

Date: 2026-07-13
Status: Approved by Brandon (menu bar terminal sessions, cmux-style)

## Goal

Embed quick-use, stored terminal sessions in FinderPath, popping up from the
menu bar like cmux workspaces. Sessions keep running while the app is open and
restore (name + working directory) across app restarts. The terminal emulator
is homegrown — no third-party libraries — keeping the zero-dependency
`swiftc` build intact.

## Non-Goals (v1)

- Mouse reporting, sixel/kitty graphics, full text reflow on resize
  (resize pads/truncates lines instead of rewrapping)
- Saving scrollback contents to disk (secrets in output must not be persisted)
- Remote/SSH session management beyond what a shell already provides
- tmux-style splits inside one session

## Emulator Scope

Target `TERM=xterm-256color` basics, enough to run shells, git, ssh, htop,
and claude/codex TUIs:

- C0 controls, UTF-8 decoding
- CSI: cursor addressing/movement, erase (ED/EL), insert/delete line & char,
  scroll region (DECSTBM), save/restore cursor, device status report
- SGR: bold, faint, italic, underline, inverse, 16/256/true color
- Modes: alternate screen (1049), autowrap (DECAWM), bracketed paste (2004),
  cursor visibility (25), application cursor keys (DECCKM)
- OSC: window title (0/2), ignore the rest safely

Unknown sequences are parsed and dropped without corrupting state.

## Architecture

New subsystem in `FinderPath/Terminal/`, each file 200–400 lines,
UI-free logic separated from AppKit for testability.

| Unit | Responsibility |
|------|----------------|
| `PTYProcess` | `openpty()` + `posix_spawn` (SETSID) of the login shell; dispatch-source reads; write, resize (`TIOCSWINSZ`), terminate; exit callback |
| `TerminalParser` | Byte state machine (ground/ESC/CSI/OSC) → typed `TerminalAction`s; UTF-8 aware |
| `TerminalScreen` | Grid of styled cells, cursor, scroll region, alternate buffer, scrollback ring; applies actions |
| `TerminalInputEncoder` | Key events + modes → bytes (arrows, Ctrl, bracketed paste) |
| `TerminalView` | `NSView` drawing the grid via CoreText; keyboard first responder; selection + copy; scroll wheel = scrollback |
| `TerminalSession` | One PTY + parser + screen; name, cwd, running/exited state; restart |
| `TerminalSessionStore` | Ordered session list; persists metadata (id, name, cwd) to Application Support JSON; restores on launch (shell relaunches lazily on first view) |
| `TerminalPanelController` | NSPopover anchored to the status item; session tab strip; pin → detached floating panel; new-session button |

Data flow: PTY bytes → parser → screen mutations → coalesced redraw
(~60 fps cap). Input: keyDown → encoder → PTY write.

## UI Integration

- **Left-click menu**: new "Terminals" section — stored sessions with a
  running indicator, "New Terminal Here" (cwd = current Finder folder),
  "Show Terminals". Selecting a session opens the panel focused on it.
- **Right-click**: opens the terminal panel directly instead of the menu.
- **Panel**: transient NSPopover under the icon; tab strip on top, terminal
  below, pin button. Pinned = detached floating utility panel (movable,
  resizable, always on top). Closing the popup never kills sessions.
- **Settings**: feature toggle, font size, scrollback limit (default 2,000
  lines), default shell override, panel default size.

## Error Handling

- Spawn failure or process exit → inline status row in the pane with the
  exit code and a Restart button; never a dead blank pane.
- Writes to an exited PTY are ignored; reads stop cleanly on EOF.
- Corrupt persistence JSON → start with an empty session list (log, don't
  crash), never block app launch.

## Testing

Parser, screen, and encoder are pure logic → dependency-free tests in the
existing `Tests/` + `script/test_logic.sh` runner: CSI parsing, SGR
application, cursor math, wrap, scroll regions, alt-screen switching,
scrollback, resize behavior, input encoding, UTF-8 splitting across reads.
PTY/UI layers verified by build + manual smoke run (`run_no_xcode.sh verify`).

## Build

- `script/run_no_xcode.sh` source glob extended to include
  `FinderPath/Terminal/*.swift`.
- New files registered in `FinderPath.xcodeproj` so Xcode builds keep working.
