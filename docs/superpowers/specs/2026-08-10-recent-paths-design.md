# Recent Paths — Design

Date: 2026-08-10
Status: Approved

## Problem

FinderPath shows and acts on the folder Finder is showing *right now*. Every
action — copy the path, open a terminal, launch an agent — is scoped to that one
live folder. Once you navigate Finder somewhere else, the previous folder is
gone, and getting back to it means finding it in Finder again first.

Recent Paths keeps a short history of the folders FinderPath has seen and offers
the same action set against any of them.

## Behavior

### What gets recorded

A path is recorded whenever FinderPath queries Finder and gets back a real
Finder window's folder. That covers opening the menu, the Refresh item, and the
right-click terminal panel — recording rides along on the existing query, so the
feature adds no Finder queries of its own.

A path is **not** recorded when the query fell back to the Desktop because no
Finder window was open. Without this distinction the history would fill with
Desktop, since opening the menu to reach Settings or a terminal is common and
that query returns Desktop every time.

Errors, timeouts, and permission denials are never recorded.

### The list

- Deduplicated by path; re-visiting a folder promotes it to the top rather than
  adding a second entry.
- Most recent first.
- Capped at 10. Recording an 11th distinct folder drops the oldest.
- Persisted, so the list is useful immediately after login.
- Cleared only by the explicit **Clear Recent Paths** command. Entries are never
  auto-pruned.

### The menu

A `Recent Paths ▸` submenu in the status menu, positioned after the agent
launchers and before the Terminals section. A submenu rather than a flat block
because the main menu already carries up to 16 items.

Each entry is itself a submenu carrying the same action set as the main menu:

```
Copy Path
Copy cd Command
────────
Open in cmux            (shown per preference + install check)
Open in Ghostty         (shown per preference + install check)
Open in Terminal        (shown per preference)
────────
Open with Codex         (shown per preference + availability)
Open with Claude        (shown per preference + availability)
Open with Hermes        (shown per preference + availability)
────────
New Terminal Here
Reveal in Finder
```

The launcher and agent rows honor exactly the same preferences and availability
rules as their main-menu counterparts, including `hideUnavailableAgentItems`.

Holding Option swaps the agent rows to *Open with <name> in FinderPath Terminal*
and runs the agent in the built-in terminal, matching the main menu.

Below the entries: a separator and **Clear Recent Paths**.

### Entry titles

The folder name alone. When two entries would render identically — two folders
both named `src` — the parent component is prepended to both (`api/src`,
`web/src`). The full path is always on the tooltip.

### Stale entries

The menu performs no filesystem checks while building. A folder that has since
been deleted, renamed, or unmounted still appears: Copy Path and Copy cd
Command still work, and the open actions surface the existing launch-failure
alert. This is deliberate — see Performance below.

## Architecture

### New: `FinderPath/RecentPaths.swift`

Follows the shape `TerminalSessionStore.swift` already established: a `Codable`
value type, a `@MainActor` store owning persistence, and a `nonisolated` pure
core the synchronous logic-test runner can link without actor hops.

```swift
struct RecentPath: Codable, Equatable {
    let path: String
    var lastVisited: Date
}

enum RecentPathsLogic {
    static func recording(_ path: String, into list: [RecentPath], at: Date, limit: Int) -> [RecentPath]
    static func menuTitles(for list: [RecentPath]) -> [String]
    static func decode(_ data: Data) -> [RecentPath]
    static func encode(_ list: [RecentPath]) -> Data
}

@MainActor final class RecentPathsStore {
    static let shared: RecentPathsStore
    private(set) var paths: [RecentPath]
    func record(_ path: String)
    func clear()
    func load()
    func persist()
}
```

Persistence target is
`~/Library/Application Support/FinderPath/recent-paths.json`, using the same
0700-directory / 0600-file hardening applied to `terminal-sessions.json`, and
the same rule that a persistence failure is logged and never propagates to the
caller. Corrupt or unreadable JSON decodes to an empty list rather than
crashing or blocking launch.

Paths are standardized before comparison so `/tmp/a` and `/tmp/a/` are one
entry.

### New: `FinderPath/RecentPathsMenu.swift`

Builds the `Recent Paths` menu and its per-entry submenus from the store plus
injected action targets. Kept out of `StatusItem.swift` for the reason
`StatusMenuViews.swift` records in its own header: that file stays the menu
controller. `StatusItem.swift` is already 612 lines against an 800-line ceiling.

The builder receives precomputed agent availability (see Performance) rather
than resolving it itself.

### Changed: `FinderPath/Bridges.swift`

The Finder query script has three exits: the front Finder window, the
`insertion location`, and the Desktop. Only the first is a folder the user
actually had open. Marking just the Desktop branch would not work, because
`insertion location` itself returns the Desktop when no window exists.

The script emits a status token on its own first line:

```applescript
return "window" & linefeed & finderPath     -- real Finder window
return "fallback" & linefeed & <desktop>    -- insertion location, or desktop
```

`interpretScriptResult` returns a struct rather than a bare `String`:

```swift
struct FinderPathQueryResult: Equatable, Sendable {
    let path: String
    let isFallback: Bool
}
```

Only the **first** line is treated as the token; everything after it is the
path. A folder name containing a newline is legal on APFS and the file already
carries a test asserting such names survive, so the parse must not split on
every newline. Output carrying no recognized token is read as a plain path with
`isFallback: false`, so the function stays correct if the script is ever
bypassed or replaced.

Errors, watchdog timeouts, permission denials, and the empty-stdout Desktop
fallback all report `isFallback: true`.

Three call sites update: `FinderPathState.refresh`, and the two branches of
`FinderPathActionRouter` that fetch a path before launching Ghostty or cmux.

### Changed: `FinderPath/FinderPathApp.swift`

`FinderPathState` records into the store on refresh when the result is a real
window path.

Its action methods currently hardcode `currentPath`. Each gains an optional
path parameter resolving to `currentPath` when nil:

```swift
func openInGhostty(at path: String? = nil) {
    guard let target = resolvedTarget(path) else { return }
    ...
}
```

Existing call sites are unchanged. The recent-path selectors pass the entry's
path. This reuses every existing guard and error-alert path instead of
duplicating them, and is the smallest change that makes the actions
path-agnostic.

### Changed: `FinderPath/StatusItem.swift`

- Computes the three agent availabilities once per `rebuildMenu` and passes them
  to both the main-menu rows and the recent-path submenu builder.
- Inserts the `Recent Paths` submenu when the preference is on and the list is
  non-empty.
- Gains selectors for the recent-path actions. Each submenu item carries its
  path in `representedObject`; agent rows carry a small value holding the path
  plus which agent, so two selectors cover all three agents rather than six.
- Agent rows inside recent-path submenus register into the existing
  `harnessMenuItemBindings` array, so the existing 30 Hz modifier poll re-titles
  and re-targets them live, exactly as it does for the main-menu rows.

## Performance

`AgentLauncher.availability` stats every directory on PATH. Resolving it per row
would cost up to 3 agents × 10 recent paths ≈ 300 filesystem calls per menu
rebuild, and `rebuildMenu` runs twice per click — once with the last-known path
and again when the async Finder query lands. Availability is therefore resolved
once per rebuild and passed down, reducing this to three lookups.

For the same reason the menu performs no `fileExists` checks on recent entries.
Building roughly 110 `NSMenuItem`s per rebuild is cheap; hitting the filesystem
110 times on every click, twice, is not — particularly with an unmounted network
volume in the list, where a stat can block.

## Settings

One toggle, **Show Recent Paths**, added to the existing *Menu Items* section
alongside the other row toggles, defaulting on, with the matching line in
`resetToDefaults`.

No configurable limit. A fixed cap of 10 is adequate and a slider is not
justified yet.

## Testing

Added to `Tests/LogicTests.swift`:

- Recording a path already in the list promotes it instead of duplicating.
- The cap holds at 10 and drops the oldest entry.
- Corrupt JSON decodes to an empty list.
- Encode/decode round-trips a populated list.
- Duplicate folder names disambiguate by parent component; unique names do not.
- Path standardization treats a trailing slash as the same entry.
- `Show Recent Paths` defaults on and an explicit off choice persists.
- `interpretScriptResult` for four cases: a `window` token (path returned, not a
  fallback), a `fallback` token (path returned, marked fallback), untokenized
  legacy output (path returned, not a fallback), and an error (marked fallback).

`script/test_logic.sh` gains `RecentPaths.swift` in its first binary's source
list. The Xcode project uses file-system-synchronized groups, so the new source
files need no project-file edit.

## Verification

1. `./script/test_logic.sh`
2. `script/run_no_xcode.sh` for a swiftc build of the app
3. Drive the live status item to confirm the submenu populates, the actions fire
   against the right folder, and Option swaps the agent rows

## Out of scope

- Pinning or favoriting entries
- Editing or reordering the list by hand
- Recording folders FinderPath never queried
- Syncing history across machines
