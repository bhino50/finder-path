# Recent Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give FinderPath a persistent list of the last 10 Finder folders it saw, each offering the app's full action set (copy, launchers, agents, terminal, reveal).

**Architecture:** `FinderBridge` learns to distinguish a real Finder window from the Desktop substitution, so only genuine folders are recorded. A new `RecentPaths.swift` holds a pure logic core plus a `@MainActor` store persisting JSON to Application Support. A new `RecentPathsMenu.swift` builds the submenu tree, keeping `StatusItem.swift` as the menu controller. `FinderPathState`'s action methods gain an optional path so recent-path rows reuse every existing guard and error path.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI (Settings only), macOS 13+. No third-party dependencies. Tests are a hand-rolled assertion runner (`Tests/LogicTests.swift`) built by `script/test_logic.sh` — not XCTest, not Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-10-recent-paths-design.md`
- **Branch:** work on `release/1.9` (current branch, clean tree at start).
- **No emojis** in code, comments, or documentation.
- **File size:** 200-400 lines typical, 800 max. `StatusItem.swift` is at 612 — keep new menu-building code out of it.
- **Comments explain why, not what.** Match the surrounding density: this codebase comments non-obvious decisions and past bugs at length, and leaves obvious code bare.
- **No `print()`** — use `NSLog` as the existing stores do.
- **Test runner:** assertions are `expect(<condition>, "<message>")` inside `FinderPathLogicTests.main()`. There is no test framework. Add assertions to the existing flat list.
- **Xcode project needs no edits** — it uses `PBXFileSystemSynchronizedRootGroup`, and `script/run_no_xcode.sh` globs `FinderPath/*.swift`.
- **Recent-path cap is 10**, defined once as `RecentPathsLogic.limit`.
- Every task ends with a passing `./script/test_logic.sh` and a commit.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `FinderPath/Bridges.swift` | Modify | Finder query gains a fallback marker; `interpretScriptResult` returns a struct |
| `FinderPath/RecentPaths.swift` | Create | `RecentPath` model, `RecentPathsLogic` pure core, `RecentPathsStore` persistence |
| `FinderPath/RecentPathsMenu.swift` | Create | Builds the Recent Paths submenu tree from the store plus injected selectors |
| `FinderPath/FinderPathApp.swift` | Modify | `FinderPathState` actions take an optional path; records on refresh; store loads at launch |
| `FinderPath/StatusItem.swift` | Modify | Precomputes availability, inserts the submenu, hosts the recent-path selectors |
| `FinderPath/Preferences.swift` | Modify | `showRecentPathsItem` key, default, accessor |
| `FinderPath/SettingsUI.swift` | Modify | `Show Recent Paths` toggle and its reset line |
| `Tests/LogicTests.swift` | Modify | Assertions for the bridge struct, the logic core, and the preference |
| `script/test_logic.sh` | Modify | Add `RecentPaths.swift` to the first test binary |
| `README.md` | Modify | Feature bullet and settings mention |

---

## Task 1: Finder query distinguishes a real window from the Desktop fallback

**Files:**
- Modify: `FinderPath/Bridges.swift:23-43` (script), `:58-134` (query and interpretation)
- Modify: `FinderPath/FinderPathApp.swift:167-195` (router), `:237-246` (refresh)
- Test: `Tests/LogicTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct FinderPathQueryResult: Equatable, Sendable { let path: String; let isFallback: Bool }`; `FinderBridge.fetchCurrentPath() async -> FinderPathQueryResult`; `FinderBridge.interpretScriptResult(terminationStatus:timedOut:stdout:stderr:) -> FinderPathQueryResult`.

**Why this shape:** The script has three exits — front Finder window, `insertion location`, Desktop. Only the first is a folder the user had open. Marking just the Desktop branch would not work, because `insertion location` itself returns the Desktop when no window exists.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LogicTests.swift`, immediately after the existing `interpretScriptResult` assertions (currently ending near line 244):

```swift
        // The query script tags its answer so the recent-paths history can tell
        // a folder the user actually had open from the desktop substitution.
        let windowResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "window\n/Users/demo/Documents\n",
            stderr: ""
        )
        expect(windowResult.path == "/Users/demo/Documents", "a window-tagged result returns the path")
        expect(!windowResult.isFallback, "a real Finder window is not a fallback")

        let fallbackResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "fallback\n/Users/demo/Desktop\n",
            stderr: ""
        )
        expect(fallbackResult.path == "/Users/demo/Desktop", "a fallback-tagged result still returns the path")
        expect(fallbackResult.isFallback, "a desktop substitution is marked as a fallback")

        // Output with no tag must still work, so the function stays correct if
        // the script is ever replaced or bypassed.
        let untaggedResult = FinderBridge.interpretScriptResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "/Users/demo/Documents\n",
            stderr: ""
        )
        expect(untaggedResult.path == "/Users/demo/Documents", "untagged output is read as a plain path")
        expect(!untaggedResult.isFallback, "untagged output is not treated as a fallback")

        // A folder name may legally contain a newline on APFS, so only the
        // FIRST newline separates the tag from the path.
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "window\n/tmp/a\nb",
                stderr: ""
            ).path == "/tmp/a\nb",
            "only the first newline splits the tag from the path"
        )

        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            ).isFallback,
            "a stalled Finder is a fallback, never a recordable path"
        )
```

Then update the six pre-existing `interpretScriptResult` assertions (lines ~191-244) to read `.path`, since the return type changed. They become:

```swift
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "/Users/demo/Documents\n",
                stderr: ""
            ).path == "/Users/demo/Documents",
            "successful query should return the trimmed path"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: true,
                stdout: "/tmp\n",
                stderr: ""
            ).path == "/tmp",
            "a completed query should win over a racing timeout"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)"
            ).path == FinderBridge.permissionDeniedMessage,
            "automation denial should map to the permission message"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 15,
                timedOut: true,
                stdout: "",
                stderr: ""
            ).path == FinderBridge.finderStalledMessage,
            "a watchdog kill should report Finder as not responding"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "execution error: Finder got an error: AppleEvent timed out. (-1712)"
            ).path.hasPrefix("Finder AppleScript error:"),
            "other script failures should surface as error strings"
        )
        expect(
            FinderBridge.interpretScriptResult(
                terminationStatus: 0,
                timedOut: false,
                stdout: "",
                stderr: ""
            ).path.hasPrefix("/"),
            "empty output should fall back to a local folder"
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/test_logic.sh`
Expected: compile failure — `value of type 'String' has no member 'path'`.

- [ ] **Step 3: Add the result type and rewrite the script**

In `FinderPath/Bridges.swift`, add above `nonisolated enum FinderBridge`:

```swift
/// The outcome of one Finder query. `isFallback` is true whenever the path did
/// not come from a real Finder window — an error, a timeout, or the desktop
/// substitution the script makes when no window is open. Recent Paths records
/// only non-fallback results, so opening the menu without a Finder window does
/// not bury the history under repeated Desktop entries.
nonisolated struct FinderPathQueryResult: Equatable, Sendable {
    let path: String
    let isFallback: Bool
}
```

Replace `pathQuerySource` (lines 23-43) with:

```swift
    // Some Finder windows, such as the Computer view, report a target that
    // cannot be coerced to a file alias. Treat those like no-window cases.
    //
    // The answer is prefixed with a status line so the caller can tell a folder
    // the user actually had open ("window") from the desktop the script
    // substitutes when there is nothing open ("fallback"). Tagging only the
    // final desktop branch would not work: `insertion location` itself returns
    // the desktop when no window exists, so that branch is a fallback too.
    private static let pathQuerySource = """
    with timeout of 3 seconds
        tell application "Finder"
            set finderPath to missing value
            if (count of Finder windows) > 0 then
                try
                    set finderPath to POSIX path of (target of front Finder window as alias)
                end try
            end if
            if finderPath is not missing value then
                return "window" & linefeed & finderPath
            end if
            try
                set finderPath to POSIX path of (insertion location as alias)
            end try
            if finderPath is missing value then
                set finderPath to POSIX path of (path to desktop folder as alias)
            end if
            return "fallback" & linefeed & finderPath
        end tell
    end timeout
    """
```

- [ ] **Step 4: Rewrite the query and interpretation to return the struct**

In the same file, change the two signatures:

```swift
    static func fetchCurrentPath() async -> FinderPathQueryResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: executePathQuery())
            }
        }
    }

    private static func executePathQuery() -> FinderPathQueryResult {
```

Inside `executePathQuery`, the `catch` on `process.run()` becomes:

```swift
        } catch {
            return FinderPathQueryResult(
                path: "Finder AppleScript error: \(error.localizedDescription)",
                isFallback: true
            )
        }
```

Replace `interpretScriptResult` wholesale:

```swift
    /// Maps an osascript run onto the path-or-error strings the UI expects.
    /// A successful path wins even when the watchdog raced the exit.
    static func interpretScriptResult(
        terminationStatus: Int32,
        timedOut: Bool,
        stdout: String,
        stderr: String
    ) -> FinderPathQueryResult {
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminationStatus == 0, !output.isEmpty {
            let parsed = parseTaggedOutput(output)
            if !parsed.path.isEmpty {
                return parsed
            }
        }
        if timedOut {
            return FinderPathQueryResult(path: finderStalledMessage, isFallback: true)
        }
        let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorText.contains(automationDeniedErrorCode) {
            return FinderPathQueryResult(path: permissionDeniedMessage, isFallback: true)
        }
        if terminationStatus != 0 {
            let detail = errorText.isEmpty
                ? "The Finder query failed (status \(terminationStatus))."
                : errorText
            return FinderPathQueryResult(
                path: "Finder AppleScript error: \(detail)",
                isFallback: true
            )
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
            .first?
            .path ?? NSHomeDirectory()
        return FinderPathQueryResult(path: desktop, isFallback: true)
    }

    /// Splits the script's status line from the path. Only the FIRST newline
    /// separates them: a folder name may legally contain a newline on APFS, and
    /// splitting on every newline would truncate such a path. Output carrying no
    /// recognized tag is read as a plain path so this stays correct if the
    /// script is ever replaced or bypassed.
    private static func parseTaggedOutput(_ output: String) -> FinderPathQueryResult {
        guard let newline = output.firstIndex(of: "\n") else {
            return FinderPathQueryResult(path: output, isFallback: false)
        }
        let path = String(output[output.index(after: newline)...])
        switch output[..<newline] {
        case "window":
            return FinderPathQueryResult(path: path, isFallback: false)
        case "fallback":
            return FinderPathQueryResult(path: path, isFallback: true)
        default:
            return FinderPathQueryResult(path: output, isFallback: false)
        }
    }
```

- [ ] **Step 5: Update the three call sites**

In `FinderPath/FinderPathApp.swift`, `FinderPathState.refresh` (line ~237):

```swift
        Task { @MainActor [weak self] in
            let result = await FinderBridge.fetchCurrentPath()
            guard let self, generation == self.refreshGeneration else { return }
            self.currentPath = result.path
            onChange?()
        }
```

In `FinderPathActionRouter.handle(url:)`, the `open-ghostty` branch (lines ~166-180):

```swift
            Task { @MainActor in
                let result = await FinderBridge.fetchCurrentPath()
                guard !result.path.hasPrefix("Finder AppleScript error:") else {
                    self.presentFailure(result.path, displayName: "Ghostty")
                    return
                }

                TerminalBridge.openGhostty(at: result.path) { error in
                    guard let error else { return }
                    Task { @MainActor in
                        self.presentFailure(error, displayName: "Ghostty")
                    }
                }
            }
```

The `open-cmux` branch (lines ~181-195) takes the identical shape, with `TerminalBridge.openCmux` and `"cmux"`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `./script/test_logic.sh`
Expected: PASS, with a higher assertion count than before.

- [ ] **Step 7: Commit**

```bash
git add FinderPath/Bridges.swift FinderPath/FinderPathApp.swift Tests/LogicTests.swift
git commit -m "feat: tell a real Finder window apart from the desktop fallback"
```

---

## Task 2: Recent paths model, logic core, and store

**Files:**
- Create: `FinderPath/RecentPaths.swift`
- Modify: `script/test_logic.sh:12-19` (source list)
- Test: `Tests/LogicTests.swift`

**Interfaces:**
- Consumes: `FinderBridge.permissionDeniedMessage` (unchanged by Task 1) for one test.
- Produces: `struct RecentPath: Codable, Equatable { let path: String; var lastVisited: Date }`; `RecentPathsLogic.limit: Int`, `.recording(_:into:at:limit:) -> [RecentPath]`, `.menuTitles(for:) -> [String]`, `.decode(_:) -> [RecentPath]`, `.encode(_:) -> Data`; `@MainActor RecentPathsStore.shared` with `paths: [RecentPath]`, `record(_:)`, `clear()`, `load()`, `persist()`.

- [ ] **Step 1: Add the new source to the test script**

In `script/test_logic.sh`, add one line to the first `swiftc` invocation's source list, keeping the existing alphabetical order:

```bash
  "$ROOT_DIR/FinderPath/Preferences.swift" \
  "$ROOT_DIR/FinderPath/RecentPaths.swift" \
  "$ROOT_DIR/FinderPath/RemoteServers.swift" \
```

- [ ] **Step 2: Write the failing tests**

Add to `Tests/LogicTests.swift`, after the Task 1 assertions:

```swift
        // Recent Paths remembers the folders FinderPath saw. Order is recency,
        // so the list logic is pure and lives outside the @MainActor store.
        let visitDate = Date(timeIntervalSinceReferenceDate: 776_000_000)

        let seeded = RecentPathsLogic.recording("/tmp/one", into: [], at: visitDate)
        expect(seeded.map(\.path) == ["/tmp/one"], "recording seeds an empty list")

        let two = RecentPathsLogic.recording("/tmp/two", into: seeded, at: visitDate)
        expect(two.map(\.path) == ["/tmp/two", "/tmp/one"], "the newest path goes to the front")

        let promoted = RecentPathsLogic.recording("/tmp/one", into: two, at: visitDate)
        expect(promoted.map(\.path) == ["/tmp/one", "/tmp/two"], "revisiting promotes instead of duplicating")

        expect(
            RecentPathsLogic.recording("/tmp/one/", into: promoted, at: visitDate).count == 2,
            "a trailing slash is the same folder, not a second entry"
        )

        // An error string is not a path and must never enter the history.
        expect(
            RecentPathsLogic.recording(
                FinderBridge.permissionDeniedMessage,
                into: seeded,
                at: visitDate
            ).count == 1,
            "an error message is never recorded as a path"
        )
        expect(
            RecentPathsLogic.recording("", into: seeded, at: visitDate).count == 1,
            "an empty path is ignored"
        )
        expect(
            RecentPathsLogic.recording("relative/path", into: seeded, at: visitDate).count == 1,
            "a relative path is ignored"
        )

        var capped: [RecentPath] = []
        for index in 0..<(RecentPathsLogic.limit + 2) {
            capped = RecentPathsLogic.recording("/tmp/folder\(index)", into: capped, at: visitDate)
        }
        expect(capped.count == RecentPathsLogic.limit, "the history is capped")
        expect(
            capped.first?.path == "/tmp/folder\(RecentPathsLogic.limit + 1)",
            "the newest entry survives the cap"
        )
        expect(!capped.contains { $0.path == "/tmp/folder0" }, "the oldest entry is dropped by the cap")

        // A bare folder name is ambiguous when two entries share it.
        let uniqueNames = [
            RecentPath(path: "/tmp/api", lastVisited: visitDate),
            RecentPath(path: "/tmp/web", lastVisited: visitDate)
        ]
        expect(
            RecentPathsLogic.menuTitles(for: uniqueNames) == ["api", "web"],
            "unique folder names stay bare"
        )

        let clashingNames = [
            RecentPath(path: "/tmp/api/src", lastVisited: visitDate),
            RecentPath(path: "/tmp/web/src", lastVisited: visitDate),
            RecentPath(path: "/tmp/docs", lastVisited: visitDate)
        ]
        expect(
            RecentPathsLogic.menuTitles(for: clashingNames) == ["api/src", "web/src", "docs"],
            "clashing names gain their parent on every occurrence, others stay bare"
        )

        expect(RecentPathsLogic.decode(Data("not json".utf8)).isEmpty, "corrupt history decodes to empty")
        expect(RecentPathsLogic.decode(Data()).isEmpty, "an empty file decodes to empty")
        expect(
            RecentPathsLogic.decode(RecentPathsLogic.encode(clashingNames)) == clashingNames,
            "history round-trips through the codec"
        )
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `./script/test_logic.sh`
Expected: compile failure — `cannot find 'RecentPathsLogic' in scope`.

- [ ] **Step 4: Create `FinderPath/RecentPaths.swift`**

```swift
import Foundation

/// One remembered Finder folder. Only the path and the moment it was last seen
/// are stored; nothing about the folder's contents reaches disk.
struct RecentPath: Codable, Equatable {
    let path: String
    var lastVisited: Date
}

/// Pure list and codec logic. Kept nonisolated so the synchronous logic-test
/// runner can exercise it without actor hops, the same split
/// TerminalSessionStore uses for its metadata codec.
nonisolated enum RecentPathsLogic {
    /// Long enough to cover a working session, short enough that the submenu
    /// stays scannable at a glance.
    static let limit = 10

    /// Returns a new list with `path` at the front. Revisiting a folder promotes
    /// its existing entry rather than duplicating it, and the result is capped so
    /// the history can never grow without bound.
    ///
    /// Only absolute paths are accepted. That single check also rejects the
    /// empty string and every "Finder AppleScript error: ..." message, so an
    /// error can never be recorded as though it were a folder.
    static func recording(
        _ path: String,
        into list: [RecentPath],
        at date: Date,
        limit: Int = limit
    ) -> [RecentPath] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return list }

        let key = standardized(trimmed)
        let remaining = list.filter { standardized($0.path) != key }
        let updated = [RecentPath(path: key, lastVisited: date)] + remaining
        return Array(updated.prefix(limit))
    }

    /// Menu titles are the folder name alone, which is ambiguous when two entries
    /// share it — two checkouts each containing "src". Any name appearing more
    /// than once gains its parent component on every occurrence, so the
    /// disambiguation is symmetric rather than singling one entry out.
    static func menuTitles(for list: [RecentPath]) -> [String] {
        let leaves = list.map(leafName(for:))
        var occurrences: [String: Int] = [:]
        for leaf in leaves {
            occurrences[leaf, default: 0] += 1
        }

        return zip(list, leaves).map { entry, leaf in
            guard (occurrences[leaf] ?? 0) > 1 else { return leaf }
            let parent = URL(fileURLWithPath: entry.path)
                .deletingLastPathComponent()
                .lastPathComponent
            return parent.isEmpty ? leaf : "\(parent)/\(leaf)"
        }
    }

    /// Corrupt or truncated data yields an empty list: a damaged history file
    /// must never crash or block app launch.
    static func decode(_ data: Data) -> [RecentPath] {
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([RecentPath].self, from: data)
        } catch {
            NSLog("RecentPathsStore: ignoring unreadable history: %@", error.localizedDescription)
            return []
        }
    }

    static func encode(_ list: [RecentPath]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// Trailing slashes and relative components must not produce a second entry
    /// for a folder already in the list.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func leafName(for entry: RecentPath) -> String {
        let name = URL(fileURLWithPath: entry.path).lastPathComponent
        return name.isEmpty ? entry.path : name
    }
}

/// Ordered history of the folders FinderPath has seen, persisted as JSON beside
/// the terminal session metadata and with the same permission hardening.
@MainActor
final class RecentPathsStore {
    static let shared = RecentPathsStore()

    private(set) var paths: [RecentPath] = []

    func record(_ path: String) {
        let updated = RecentPathsLogic.recording(path, into: paths, at: Date())
        // Reopening the menu in the folder already at the front moves only the
        // timestamp. Persisting that would mean a disk write on every single
        // menu click, so the file is rewritten only when the order changes.
        let orderChanged = updated.map(\.path) != paths.map(\.path)
        paths = updated
        guard orderChanged else { return }
        persist()
    }

    func clear() {
        guard !paths.isEmpty else { return }
        paths = []
        persist()
    }

    func load() {
        let url = Self.persistenceURL()
        // Upgrade permissions before reading so a file written by an older build
        // stops exposing folder names to other local accounts right away, rather
        // than whenever the list next happens to change.
        try? Self.hardenPermissions(at: url)
        guard let data = try? Data(contentsOf: url) else { return }
        paths = RecentPathsLogic.decode(data)
    }

    func persist() {
        let url = Self.persistenceURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try RecentPathsLogic.encode(paths).write(to: url, options: .atomic)
            try Self.hardenPermissions(at: url)
        } catch {
            // A history that cannot be saved must never take the app down.
            NSLog("RecentPathsStore: failed to persist history: %@", error.localizedDescription)
        }
    }

    private nonisolated static func persistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FinderPath/recent-paths.json")
    }

    private nonisolated static func hardenPermissions(at url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./script/test_logic.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add FinderPath/RecentPaths.swift Tests/LogicTests.swift script/test_logic.sh
git commit -m "feat: add the recent paths store and list logic"
```

---

## Task 3: Preference and Settings toggle

**Files:**
- Modify: `FinderPath/Preferences.swift:4-19` (keys), `:48-89` (defaults), `:99-106` (accessors)
- Modify: `FinderPath/SettingsUI.swift:33-67` (storage), `:92-106` (Menu Items), `:302-337` (reset)
- Test: `Tests/LogicTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `FinderPathPreferences.showRecentPathsItemKey: String`, `FinderPathPreferences.showRecentPathsItem: Bool`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LogicTests.swift`, after the Task 2 assertions:

```swift
        // Every menu row has a visibility toggle; Recent Paths follows suit and
        // ships on, with an explicit off choice surviving relaunch.
        let recentPathsKey = FinderPathPreferences.showRecentPathsItemKey
        UserDefaults.standard.removeObject(forKey: recentPathsKey)
        FinderPathPreferences.registerDefaults()
        expect(FinderPathPreferences.showRecentPathsItem, "Recent Paths should be shown by default")
        UserDefaults.standard.set(false, forKey: recentPathsKey)
        expect(!FinderPathPreferences.showRecentPathsItem, "hiding Recent Paths must persist")
        UserDefaults.standard.removeObject(forKey: recentPathsKey)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./script/test_logic.sh`
Expected: compile failure — `type 'FinderPathPreferences' has no member 'showRecentPathsItemKey'`.

- [ ] **Step 3: Add the key, default, and accessor**

In `FinderPath/Preferences.swift`, add the key after `showCopyCDItemKey` (line 7):

```swift
    static let showRecentPathsItemKey = "showRecentPathsItem"
```

Add to the `registerDefaults` dictionary, after `showCopyCDItemKey: true,`:

```swift
            showRecentPathsItemKey: true,
```

Add the accessor after `showCopyCDItem` (line ~105):

```swift
    static var showRecentPathsItem: Bool {
        bool(for: showRecentPathsItemKey, defaultValue: true)
    }
```

- [ ] **Step 4: Add the Settings toggle**

In `FinderPath/SettingsUI.swift`, add storage after `showCopyCDItem` (line 36):

```swift
    @AppStorage(FinderPathPreferences.showRecentPathsItemKey) private var showRecentPathsItem = true
```

Add the toggle to the `Menu Items` section, after `Toggle("Show Copy cd Command", isOn: $showCopyCDItem)` (line 96):

```swift
                Toggle("Show Recent Paths", isOn: $showRecentPathsItem)
```

Add to `resetDefaults()`, after `showCopyCDItem = true` (line ~306):

```swift
        showRecentPathsItem = true
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./script/test_logic.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add FinderPath/Preferences.swift FinderPath/SettingsUI.swift Tests/LogicTests.swift
git commit -m "feat: add the Show Recent Paths preference"
```

---

## Task 4: Path-agnostic actions and recording on refresh

**Files:**
- Modify: `FinderPath/FinderPathApp.swift:68-84` (launch), `:229-358` (`FinderPathState`)
- Modify: `FinderPath/StatusItem.swift:525-535` (the three agent selectors)

**Interfaces:**
- Consumes: `FinderPathQueryResult` (Task 1); `RecentPathsStore.shared` (Task 2).
- Produces: on `FinderPathState` — `copyCurrentPath(at:)`, `copyChangeDirectoryCommand(at:)`, `openInTerminal(at:)`, `openInGhostty(at:)`, `openInCmux(at:)`, `revealInFinder(at:)`, and `openWithAgent(named:executable:at:)`, all taking `String? = nil`. The three `openWithCodex()` / `openWithClaude()` / `openWithHermes()` methods are **removed** in favor of `openWithAgent`.

**Why:** Recent-path rows need the same actions against a different folder. A defaulted parameter reuses every existing guard and error-alert path; duplicating them would be three-fold DRY damage. Collapsing the three agent methods into one removes about 36 lines of near-identical code that would otherwise each need the new parameter.

- [ ] **Step 1: Add the target resolver and convert the action methods**

In `FinderPath/FinderPathApp.swift`, inside `FinderPathState`, add after `hasCopyablePath` (line ~344):

```swift
    /// Recent-path rows pass an explicit folder; every other caller acts on the
    /// live Finder path. A nil argument therefore means "whatever Finder is
    /// showing", and yields nil when there is nothing usable to act on.
    private func resolvedTarget(_ path: String?) -> String? {
        if let path, !path.isEmpty { return path }
        return hasCopyablePath ? currentPath : nil
    }
```

Replace the copy and launcher methods (lines ~248-282):

```swift
    func copyCurrentPath(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        copyToPasteboard(target)
    }

    func copyChangeDirectoryCommand(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        copyToPasteboard("cd \(ShellCommand.argument(target, quoteStyle: FinderPathPreferences.cdQuoteStyle))")
    }

    func openInTerminal(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        TerminalBridge.open(at: target) { error in
            self.presentLaunchFailure(error, displayName: "Terminal")
        }
    }

    func openInGhostty(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        TerminalBridge.openGhostty(at: target) { error in
            self.presentLaunchFailure(error, displayName: "Ghostty")
        }
    }

    func openInCmux(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        TerminalBridge.openCmux(at: target) { error in
            self.presentLaunchFailure(error, displayName: "cmux")
        }
    }

    /// Opens the folder in Finder. Passing nil for the file selects nothing and
    /// simply reveals the folder itself.
    func revealInFinder(at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target)
    }
```

Delete `openWithCodex()`, `openWithClaude()`, and `openWithHermes()` (lines ~284-327) and replace them with:

```swift
    /// One launcher for all three agents: the three previous methods differed
    /// only in which preference they read and which name they reported.
    func openWithAgent(named name: String, executable: String, at path: String? = nil) {
        guard let target = resolvedTarget(path) else { return }

        let resolvedExecutable = AgentLauncher.availability(for: executable).resolvedPath ?? executable

        TerminalBridge.openAgent(
            displayName: name,
            executable: resolvedExecutable,
            at: target
        ) { error in
            self.presentLaunchFailure(error, displayName: name)
        }
    }
```

- [ ] **Step 2: Record on refresh**

Replace `FinderPathState.refresh` (line ~237):

```swift
    /// Fetches the Finder path off the main thread and reports back on the
    /// main actor, so a stalled Finder can never beachball the app. Stale
    /// completions from an earlier refresh are dropped.
    func refresh(onChange: (() -> Void)? = nil) {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task { @MainActor [weak self] in
            let result = await FinderBridge.fetchCurrentPath()
            guard let self, generation == self.refreshGeneration else { return }
            self.currentPath = result.path
            // Only folders that were genuinely open in a Finder window are worth
            // remembering. The desktop substitution would otherwise dominate the
            // history, because opening the menu to reach Settings or a terminal
            // returns it every time.
            if !result.isFallback, self.hasCopyablePath {
                RecentPathsStore.shared.record(result.path)
            }
            onChange?()
        }
    }
```

- [ ] **Step 3: Load the history at launch**

In `applicationDidFinishLaunching`, immediately after `TerminalSessionStore.shared.loadPersistedSessions()` (line ~82):

```swift
        RecentPathsStore.shared.load()
```

- [ ] **Step 4: Update the three agent selectors in StatusItem**

In `FinderPath/StatusItem.swift`, replace the three methods at lines ~525-535:

```swift
    @objc private func openWithCodexMenuItem() {
        state.openWithAgent(named: "Codex", executable: FinderPathPreferences.codexExecutable)
    }

    @objc private func openWithClaudeMenuItem() {
        state.openWithAgent(named: "Claude", executable: FinderPathPreferences.claudeExecutable)
    }

    @objc private func openWithHermesMenuItem() {
        state.openWithAgent(named: "Hermes", executable: FinderPathPreferences.hermesExecutable)
    }
```

- [ ] **Step 5: Verify it builds and tests pass**

Run: `./script/test_logic.sh && ./script/run_no_xcode.sh build`
Expected: tests PASS, build succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add FinderPath/FinderPathApp.swift FinderPath/StatusItem.swift
git commit -m "feat: make path actions folder-agnostic and record visited folders"
```

---

## Task 5: The Recent Paths submenu

**Files:**
- Create: `FinderPath/RecentPathsMenu.swift`
- Modify: `FinderPath/StatusItem.swift:44-48` (statics), `:190-416` (`rebuildMenu`), `:553-599` (harness terminal and new selectors)

**Interfaces:**
- Consumes: `RecentPath`, `RecentPathsLogic.menuTitles(for:)`, `RecentPathsStore.shared` (Task 2); `FinderPathPreferences.showRecentPathsItem` (Task 3); `FinderPathState.copyCurrentPath(at:)` and siblings (Task 4).
- Produces: `RecentPathAgentTarget`, `RecentPathAgentOption`, `RecentPathLauncherAvailability`, `RecentPathActions`, `RecentPathsMenu.makeMenu(...)`.

**Why availability is injected:** `AgentLauncher.availability` and `TerminalBridge.isCmuxInstalled` stat every directory on PATH. Resolving them per row would cost roughly 300 filesystem calls per menu rebuild, and `rebuildMenu` runs twice per click — once with the last-known path and again when the async Finder query lands.

- [ ] **Step 1: Create `FinderPath/RecentPathsMenu.swift`**

```swift
import AppKit

/// Which agent a recent-path row launches, and where. Carried on the item's
/// representedObject so two selectors cover all three agents rather than six
/// near-identical ones.
final class RecentPathAgentTarget: NSObject {
    let path: String
    let name: String
    let executable: String

    init(path: String, name: String, executable: String) {
        self.path = path
        self.name = name
        self.executable = executable
        super.init()
    }
}

/// One agent the menu may offer. Availability is resolved once per menu rebuild
/// and passed in, because resolving it stats every directory on PATH.
struct RecentPathAgentOption {
    let name: String
    let executable: String
    let availability: AgentAvailability
    let isEnabled: Bool
}

/// Launcher installation checks, resolved once per rebuild for the same reason.
struct RecentPathLauncherAvailability {
    let isCmuxInstalled: Bool
    let isGhosttyInstalled: Bool
}

/// Selectors the rows send back to the status item controller. Non-agent rows
/// carry their folder as a String representedObject; agent rows carry a
/// RecentPathAgentTarget.
struct RecentPathActions {
    let copyPath: Selector
    let copyCDCommand: Selector
    let openInCmux: Selector
    let openInGhostty: Selector
    let openInTerminal: Selector
    let openWithAgent: Selector
    let openAgentInTerminal: Selector
    let newTerminal: Selector
    let revealInFinder: Selector
    let clear: Selector
}

/// Builds the Recent Paths submenu tree. Kept out of StatusItemController for
/// the reason StatusMenuViews records: that file stays the menu controller.
@MainActor
enum RecentPathsMenu {
    /// Returns nil when there is nothing to show, so the caller can skip the
    /// separator as well as the row.
    static func makeMenu(
        paths: [RecentPath],
        launchers: RecentPathLauncherAvailability,
        agents: [RecentPathAgentOption],
        hideUnavailableAgents: Bool,
        optionHeld: Bool,
        target: AnyObject,
        actions: RecentPathActions,
        registerAgentItem: (NSMenuItem, RecentPathAgentOption) -> Void
    ) -> NSMenu? {
        guard !paths.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        for (entry, title) in zip(paths, RecentPathsLogic.menuTitles(for: paths)) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = entry.path
            item.submenu = makeEntryMenu(
                path: entry.path,
                launchers: launchers,
                agents: agents,
                hideUnavailableAgents: hideUnavailableAgents,
                optionHeld: optionHeld,
                target: target,
                actions: actions,
                registerAgentItem: registerAgentItem
            )
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Recent Paths", action: actions.clear, keyEquivalent: "")
        clearItem.target = target
        menu.addItem(clearItem)

        return menu
    }

    /// The action set mirrors the main menu, honoring the same visibility
    /// preferences and install checks, so a recent folder is never offered an
    /// action the current folder would not be.
    private static func makeEntryMenu(
        path: String,
        launchers: RecentPathLauncherAvailability,
        agents: [RecentPathAgentOption],
        hideUnavailableAgents: Bool,
        optionHeld: Bool,
        target: AnyObject,
        actions: RecentPathActions,
        registerAgentItem: (NSMenuItem, RecentPathAgentOption) -> Void
    ) -> NSMenu {
        func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = path
            return item
        }

        var launcherItems: [NSMenuItem] = []
        if FinderPathPreferences.showOpenCmuxItem, launchers.isCmuxInstalled {
            launcherItems.append(makeItem("Open in cmux", actions.openInCmux))
        }
        if FinderPathPreferences.showOpenGhosttyItem, launchers.isGhosttyInstalled {
            launcherItems.append(makeItem("Open in Ghostty", actions.openInGhostty))
        }
        if FinderPathPreferences.showOpenTerminalItem {
            launcherItems.append(makeItem("Open in Terminal", actions.openInTerminal))
        }

        var agentItems: [NSMenuItem] = []
        for agent in agents where agent.isEnabled {
            guard agent.availability.isInstalled else {
                guard !hideUnavailableAgents else { continue }
                let item = NSMenuItem(title: "\(agent.name) Not Installed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                agentItems.append(item)
                continue
            }

            let presentation = AgentLauncher.menuPresentation(name: agent.name, optionHeld: optionHeld)
            let item = NSMenuItem(
                title: presentation.title,
                action: presentation.usesBuiltInTerminal ? actions.openAgentInTerminal : actions.openWithAgent,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = RecentPathAgentTarget(
                path: path,
                name: agent.name,
                executable: agent.executable
            )
            agentItems.append(item)
            // Registering with the controller lets its modifier poll re-title
            // and re-target this row live while the menu is already open.
            registerAgentItem(item, agent)
        }

        let groups: [[NSMenuItem]] = [
            [
                makeItem("Copy Path", actions.copyPath),
                makeItem("Copy cd Command", actions.copyCDCommand)
            ],
            launcherItems,
            agentItems,
            [
                makeItem("New Terminal Here", actions.newTerminal),
                makeItem("Reveal in Finder", actions.revealInFinder)
            ]
        ]

        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 {
                menu.addItem(.separator())
            }
            group.forEach { menu.addItem($0) }
        }
        return menu
    }
}
```

- [ ] **Step 2: Resolve availability once per rebuild in StatusItem**

In `FinderPath/StatusItem.swift`, add this method to `StatusItemController`, just above `rebuildMenu` (line ~190):

```swift
    /// The agents the menu may offer, in display order. Availability stats every
    /// directory on PATH, so it is resolved here once per rebuild and handed to
    /// every row that needs it — doing it per row would mean hundreds of
    /// filesystem calls each time the menu is built, twice per click.
    private func agentOptions() -> [RecentPathAgentOption] {
        [
            ("Codex", FinderPathPreferences.codexExecutable, FinderPathPreferences.showOpenWithCodexItem),
            ("Claude", FinderPathPreferences.claudeExecutable, FinderPathPreferences.showOpenWithClaudeItem),
            ("Hermes", FinderPathPreferences.hermesExecutable, FinderPathPreferences.showOpenWithHermesItem)
        ].map { name, executable, isEnabled in
            RecentPathAgentOption(
                name: name,
                executable: executable,
                availability: AgentLauncher.availability(for: executable),
                isEnabled: isEnabled
            )
        }
    }
```

Inside `rebuildMenu`, immediately after `let isPermissionDenied = ...` (line ~195), add:

```swift
        let agents = agentOptions()
        let launcherAvailability = RecentPathLauncherAvailability(
            isCmuxInstalled: TerminalBridge.isCmuxInstalled,
            isGhosttyInstalled: TerminalBridge.isGhosttyInstalled
        )
```

In the cmux block (line ~266), replace `let isInstalled = TerminalBridge.isCmuxInstalled` with:

```swift
            let isInstalled = launcherAvailability.isCmuxInstalled
```

In the Ghostty block (line ~278), replace `let isInstalled = TerminalBridge.isGhosttyInstalled` with:

```swift
            let isInstalled = launcherAvailability.isGhosttyInstalled
```

Replace `addHarnessItem` and its three call sites (lines ~304-351) with:

```swift
        func addHarnessItem(_ agent: RecentPathAgentOption, externalAction: Selector, terminalAction: Selector) {
            guard agent.isEnabled else { return }
            guard !hideUnavailableAgents || agent.availability.isInstalled else { return }
            addPendingLauncherSeparator()
            guard agent.availability.isInstalled else {
                let item = NSMenuItem(title: "\(agent.name) Not Installed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }
            let presentation = AgentLauncher.menuPresentation(name: agent.name, optionHeld: optionHeld)
            let action = presentation.usesBuiltInTerminal ? terminalAction : externalAction
            let item = NSMenuItem(title: presentation.title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = state.hasCopyablePath
            menu.addItem(item)
            harnessMenuItemBindings.append(
                HarnessMenuItemBinding(
                    item: item,
                    name: agent.name,
                    externalAction: externalAction,
                    terminalAction: terminalAction
                )
            )
        }

        addHarnessItem(
            agents[0],
            externalAction: #selector(openWithCodexMenuItem),
            terminalAction: #selector(openCodexInTerminalMenuItem)
        )
        addHarnessItem(
            agents[1],
            externalAction: #selector(openWithClaudeMenuItem),
            terminalAction: #selector(openClaudeInTerminalMenuItem)
        )
        addHarnessItem(
            agents[2],
            externalAction: #selector(openWithHermesMenuItem),
            terminalAction: #selector(openHermesInTerminalMenuItem)
        )
```

- [ ] **Step 3: Insert the Recent Paths row**

In `rebuildMenu`, immediately after the three `addHarnessItem` calls and **before** the `if FinderPathPreferences.showTerminalsSection` block (line ~353):

```swift
        if FinderPathPreferences.showRecentPathsItem,
           let recentPathsMenu = RecentPathsMenu.makeMenu(
               paths: RecentPathsStore.shared.paths,
               launchers: launcherAvailability,
               agents: agents,
               hideUnavailableAgents: hideUnavailableAgents,
               optionHeld: optionHeld,
               target: self,
               actions: Self.recentPathActions,
               registerAgentItem: { [weak self] item, agent in
                   self?.harnessMenuItemBindings.append(
                       HarnessMenuItemBinding(
                           item: item,
                           name: agent.name,
                           externalAction: Self.recentPathActions.openWithAgent,
                           terminalAction: Self.recentPathActions.openAgentInTerminal
                       )
                   )
               }
           ) {
            menu.addItem(.separator())
            let recentPathsItem = NSMenuItem(title: "Recent Paths", action: nil, keyEquivalent: "")
            recentPathsItem.submenu = recentPathsMenu
            menu.addItem(recentPathsItem)
        }
```

Add the selector table as a static property on `StatusItemController`, next to `copyConfirmationNanoseconds` (line ~48):

```swift
    private static let recentPathActions = RecentPathActions(
        copyPath: #selector(copyRecentPathMenuItem(_:)),
        copyCDCommand: #selector(copyRecentCDCommandMenuItem(_:)),
        openInCmux: #selector(openRecentInCmuxMenuItem(_:)),
        openInGhostty: #selector(openRecentInGhosttyMenuItem(_:)),
        openInTerminal: #selector(openRecentInTerminalMenuItem(_:)),
        openWithAgent: #selector(openRecentWithAgentMenuItem(_:)),
        openAgentInTerminal: #selector(openRecentAgentInTerminalMenuItem(_:)),
        newTerminal: #selector(newTerminalAtRecentPathMenuItem(_:)),
        revealInFinder: #selector(revealRecentPathMenuItem(_:)),
        clear: #selector(clearRecentPathsMenuItem)
    )
```

- [ ] **Step 4: Add the recent-path selectors**

In `FinderPath/StatusItem.swift`, add after `showTerminalsMenuItem` (line ~599):

```swift
    // MARK: - Recent path actions
    //
    // Non-agent rows carry their folder as a String representedObject; agent
    // rows carry a RecentPathAgentTarget. A row whose object is missing or of
    // the wrong type is ignored rather than falling back to the current Finder
    // path, which would silently act on the wrong folder.

    @objc private func copyRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.copyCurrentPath(at: path)
        showCopyConfirmation()
    }

    @objc private func copyRecentCDCommandMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.copyChangeDirectoryCommand(at: path)
        showCopyConfirmation()
    }

    @objc private func openRecentInCmuxMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInCmux(at: path)
    }

    @objc private func openRecentInGhosttyMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInGhostty(at: path)
    }

    @objc private func openRecentInTerminalMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.openInTerminal(at: path)
    }

    @objc private func openRecentWithAgentMenuItem(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? RecentPathAgentTarget else { return }
        state.openWithAgent(named: agent.name, executable: agent.executable, at: agent.path)
    }

    @objc private func openRecentAgentInTerminalMenuItem(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? RecentPathAgentTarget else { return }
        openHarnessTerminal(executable: agent.executable, name: agent.name, directory: agent.path)
    }

    @objc private func newTerminalAtRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let button = statusItem.button else { return }
        let session = TerminalSessionStore.shared.newSession(name: nil, workingDirectory: path)
        terminalPanelController.show(session: session, relativeTo: button)
    }

    @objc private func revealRecentPathMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        state.revealInFinder(at: path)
    }

    @objc private func clearRecentPathsMenuItem() {
        RecentPathsStore.shared.clear()
    }
```

- [ ] **Step 5: Let `openHarnessTerminal` take an explicit folder**

Replace the method at line ~555:

```swift
    /// Opens a new built-in terminal that runs the given agent command once the
    /// shell is ready. A nil directory means the current Finder folder; recent
    /// path rows pass their own.
    private func openHarnessTerminal(executable: String, name: String, directory: String? = nil) {
        guard let button = statusItem.button else { return }
        guard let resolvedPath = AgentLauncher.availability(for: executable).resolvedPath else {
            FinderPathAlertPresenter.presentLaunchFailure(
                "\(name) CLI was not found. Check its command or path in FinderPath Settings.",
                displayName: name
            )
            return
        }
        let workingDirectory = directory ?? (state.hasCopyablePath ? state.currentPath : NSHomeDirectory())
        let session = TerminalSessionStore.shared.newSession(
            name: name,
            workingDirectory: workingDirectory,
            initialCommand: ShellCommand.argument(resolvedPath)
        )
        DispatchQueue.main.async { [weak self] in
            self?.terminalPanelController.show(session: session, relativeTo: button)
        }
    }
```

- [ ] **Step 6: Build and run the tests**

Run: `./script/test_logic.sh && ./script/run_no_xcode.sh build`
Expected: tests PASS, build succeeds.

- [ ] **Step 7: Verify in the running app**

Run: `./script/run_no_xcode.sh`

Then, in the launched dev build:
1. Open a Finder window on a folder, click the FinderPath status item, close the menu.
2. Navigate Finder to a second folder, open the menu again.
3. Confirm `Recent Paths` lists both folders, newest first, with full paths in the tooltips.
4. Open one entry's submenu; confirm `Copy Path` puts that folder — not the current one — on the clipboard.
5. Hold Option with an entry's submenu open; confirm the agent rows re-title to "in FinderPath Terminal" while the menu stays open.
6. Close every Finder window, then open the menu twice; confirm Desktop is **not** added to the list.
7. Click `Clear Recent Paths`; reopen the menu and confirm the section is gone.
8. Quit the dev build and relaunch it; confirm the list is restored from disk.

Note: this dev build runs from `.build/no-xcode` as a separate instance from `/Applications/FinderPath.app`.

- [ ] **Step 8: Commit**

```bash
git add FinderPath/RecentPathsMenu.swift FinderPath/StatusItem.swift
git commit -m "feat: add the Recent Paths menu with the full action set"
```

---

## Task 6: Documentation

**Files:**
- Modify: `README.md:22-33` (Features)

- [ ] **Step 1: Add the feature bullet**

In `README.md`, add immediately after the `Copy cd Command` bullet:

```markdown
- **Recent Paths** — the last 10 folders FinderPath saw, each with the full action set: copy the path or `cd` command, open it in cmux, Ghostty, or Terminal, launch Codex, Claude, or Hermes there, start a built-in terminal, or reveal it in Finder. Only folders you actually had open in a Finder window are remembered, the list survives a restart, and **Clear Recent Paths** wipes it.
```

- [ ] **Step 2: Mention the toggle in the settings bullet**

In the `Configurable Settings` bullet, change the opening clause `toggle menu items;` to:

```markdown
toggle menu items (including Recent Paths);
```

- [ ] **Step 3: Verify the docs lint clean**

Run: `npx markdownlint-cli 'README.md'`
Expected: no output. If markdownlint cannot be fetched offline, skip this step and say so in the commit body.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the Recent Paths feature"
```

---

## Self-Review Notes

**Spec coverage.** Every spec section maps to a task: recording rules and the fallback marker to Task 1; list semantics, persistence, and permission hardening to Task 2; the Settings toggle to Task 3; recording on refresh and path-agnostic actions to Task 4; the submenu, agent rows, Option swap, Clear command, and the precomputed-availability performance requirement to Task 5; docs to Task 6. The spec's "Out of scope" items appear in no task, as intended.

**Deviation from the spec, deliberate.** The spec sketched `RecentPathsStore.record` as persisting on every call. Task 2 persists only when the ordered path list changes, because reopening the menu in the folder already at the front would otherwise write the file on every menu click. The in-memory timestamp still updates.

**Deviation from the spec, deliberate.** Task 4 removes `openWithCodex()` / `openWithClaude()` / `openWithHermes()` in favor of one `openWithAgent(named:executable:at:)`. The spec implied keeping them; collapsing them removes about 36 lines of triplicated code that would otherwise each have needed the new path parameter.

**Known fragility.** `agents[0...2]` in Task 5 Step 2 is positional. `agentOptions()` builds the array in a fixed Codex / Claude / Hermes order and both live in the same file, but a fourth agent would require revisiting that pairing.
