# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FinderPath is a macOS menu bar utility (LSUIElement agent app, no Dock icon, no main window) that shows the POSIX path of the frontmost Finder window. It targets macOS 13+, is written in Swift, and is structured as an Xcode project (not SwiftPM).

The entire app lives in one file: `FinderPath/FinderPathApp.swift` (~1700 lines). When changing behavior, expect to edit that single file rather than navigating a multi-module layout. Keeping it single-file is also what lets `script/run_no_xcode.sh` build the app by compiling one source with `swiftc` — if you split the file, update that script too.

## Commands

All commands are run from the `FinderPath/` directory (the inner one that contains `FinderPath.xcodeproj`).

| Action | Command |
|---|---|
| Build + launch (Debug) | `./script/build_and_run.sh` |
| Build + launch without Xcode (swiftc, no .xcodeproj) | `./script/run_no_xcode.sh` (also `build` / `verify` modes) |
| Build + launch in lldb | `./script/build_and_run.sh debug` |
| Build + stream `log` for the process | `./script/build_and_run.sh logs` |
| Build + stream telemetry for the bundle ID | `./script/build_and_run.sh telemetry` |
| Build + verify the app is actually running | `./script/build_and_run.sh verify` |
| Local-test Release ZIP + DMG | `./script/package_release.sh` |
| Signed + notarized Release | `DEVELOPER_ID="Developer ID Application: ..." NOTARY_PROFILE="FinderPathNotary" ./script/package_release.sh` |
| Direct Xcode build | `xcodebuild -project FinderPath.xcodeproj -scheme FinderPath -configuration Debug build` |

`build_and_run.sh` does `pkill -x FinderPath` before launching, so re-running it cleanly replaces a running instance. Derived data lives under `.build/`, releases under `dist/` — both are gitignored.

There is no test target. Do not invent test commands; if you add one, wire it into the Xcode project and a script before referencing it.

## Architecture

The app is one Swift file with cleanly separated layers — when adding a feature, identify which layer it belongs in rather than threading it through `AppDelegate`.

**Lifecycle**
- `FinderPathApp` (SwiftUI `App`) only exists to host the `Settings` scene. It does **not** drive UI — `NSApplicationDelegateAdaptor` hands off to `AppDelegate`.
- `AppDelegate.applicationDidFinishLaunching` registers defaults, sets `NSApp.setActivationPolicy(.accessory)`, and creates the `StatusItemController`. This is the real entry point.

**Menu bar UI (AppKit, not SwiftUI)**
- `StatusItemController` owns the `NSStatusItem`, builds the `NSMenu` on every click in `rebuildMenu(_:)`, and routes `@objc` actions to `FinderPathState`. Menu items are conditionally added based on `FinderPathPreferences` toggles, so changes to the menu happen here.
- `PathMenuHeaderView` is a custom `NSView` used as `menuItem.view` to render the path header with width/font/truncation from preferences.
- The status item handles both left- and right-click via `sendAction(on: [.leftMouseUp, .rightMouseUp])` and pops the menu manually with `menu.popUp(...)` — do not switch it to `statusItem.menu = menu` or the click-and-drag UX breaks (see the comment at the `if let button = statusItem.button` block).

**Settings UI (SwiftUI)**
- `SettingsView` is a `Form` bound to `@AppStorage` keys. The same keys are read back through `FinderPathPreferences` static getters. **Always add new preferences in both places**: a `static let xxxKey`, a default in `registerDefaults()`, a typed getter in `FinderPathPreferences`, and a corresponding `@AppStorage` + UI control in `SettingsView`. Also reset it in `resetDefaults()`.
- `SettingsWindowController` is an `NSWindowController` so the Settings window can be re-opened after closing (`isReleasedWhenClosed = false`).

**State and side effects**
- `FinderPathState` is `@MainActor` and holds the current path string. All copy/open actions live here and short-circuit on `hasCopyablePath` (path is non-empty and not an AppleScript error string).

**Bridges to the system** — these are the only places that talk to the outside world; keep them pure and side-effect-focused.
- `FinderBridge.currentPath()` uses `NSAppleScript` to ask Finder for the front window's target as a POSIX path, with a desktop fallback when no Finder windows are open. Errors are returned as `"Finder AppleScript error: ..."` strings, not thrown — downstream code detects them with `hasPrefix("Finder AppleScript error:")`.
- `TerminalBridge.open(at:)` uses `NSWorkspace` to open a folder in Terminal. `TerminalBridge.openAgent(...)` uses Terminal's AppleScript `do script` because running a command in a new Terminal session can't be done through `NSWorkspace`. `openGhostty(at:)` and `openCmux(at:)` launch those apps in the current folder (cmux is resolved via `cmuxExecutablePath()`, which checks the shell PATH and the app bundle). Both escape shell and AppleScript strings carefully — use `ShellCommand.argument(_:quoteStyle:)` and the local `appleScriptString(_:)` helper rather than building strings ad hoc.
- **Remote connections** are three cooperating pieces, all in the same file. `RemoteServers.parse(_:)/serialize(_:)` convert between the user's curated `Name = target` text (stored in the `remoteServers` default) and `[RemoteServer]`. `TailscaleBridge` shells out to the `tailscale` CLI: `status()` parses `tailscale status --json` into a `TailscaleStatus` (backend state + `[TailscaleDevice]`), and `up()`/`down()` toggle the VPN. `TerminalBridge.openSSH(host:using:)` runs `ssh <host>` in Ghostty (`open -n … --args -e ssh host`, no shell so the host is a bare arg) or Terminal (AppleScript `do script`, so the host is `ShellCommand.argument`-quoted). Tailscale device targets use the **MagicDNS short name** (first label of `DNSName`), not `HostName`, so `ssh <name>` resolves and matches `~/.ssh/config` aliases.
- `RemoteConnectionWindowController` hosts `RemoteConnectionView` (SwiftUI) — the "Connect to Server" window — and follows the same `isReleasedWhenClosed = false` pattern as `SettingsWindowController`. It opens from the `Connect to Server…` menu item and from the `finderpath://connect` URL action, which `AppDelegate` wires via `FinderPathActionRouter.onOpenConnectWindow`. The router also handles `finderpath://open-ghostty` and `finderpath://open-cmux`.
- `AgentLauncher.availability(for:)` spawns `/bin/zsh -lc` with an augmented `PATH` (`/opt/homebrew/bin:/usr/local/bin:~/.local/bin:...`) because GUI apps don't inherit the user's interactive PATH. This is how Codex/Claude/Hermes CLIs are discovered. The shell snippet handles both bare command names (via `command -v`) and absolute executable paths.
- `ShellCommand.argument(_:quoteStyle:)` is the single source of shell-quoting truth. `"single"` uses the standard `'…'\''…'` trick; `"double"` escapes `\ " $ \``. Always route user-supplied paths through this before interpolating into a command.
- `UpdateChecker.check(manifestURL:completion:)` fetches an update manifest over `URLSession` and reports `upToDate` / `updateAvailable` / `failed`. The parser auto-detects two shapes: a GitHub Releases response (presence of `tag_name`, with `body` notes and the first `.dmg` from `assets[].browser_download_url`, falling back to the first `.zip` and then `html_url`) or a plain `{ version, downloadURL, notes }` JSON manifest. When the URL host is `api.github.com` it adds the `Accept: application/vnd.github+json`, `X-GitHub-Api-Version`, and `User-Agent` headers. `UpdateChecker.compare(_:isNewerThan:)` is the numeric dot-segment comparator — extend it there, not at call sites. `UpdatePrompt.present(...)` (annotated `@MainActor`) renders the result as an `NSAlert`; silent failures are suppressed unless `userInitiated` is true. Default source URL is `https://api.github.com/repos/bhino50/finder-path/releases/latest`; to ship an update, bump `MARKETING_VERSION`, build with `package_release.sh`, then `gh release create vX.Y dist/FinderPath-X.Y.dmg`. The `download-site/version.json` file is a legacy plain-manifest fallback — not the source of truth.

**Permissions and entitlements**
- `Info.plist` declares `LSUIElement=YES`, `LSMinimumSystemVersion=13.0`, and `NSAppleEventsUsageDescription`. The first AppleScript call to Finder (and later Terminal) triggers macOS Automation prompts; if denied, errors surface as strings in the path header rather than crashing.
- App Sandbox is **off** in this build (intentional, per `README.md`). Hardened Runtime is on for Release because Developer ID notarization requires it. If you re-enable sandboxing, Apple Events entitlements for `com.apple.finder` and `com.apple.Terminal` must be added back.

## Conventions

- Single-file source is intentional for now. If you split the file, keep the layer boundaries above (`StatusItemController` / `FinderPathState` / `FinderPathPreferences` / bridges) and update both scripts and the Xcode project file references.
- All UI-touching types are annotated `@MainActor`. Keep new types in that isolation unless they're pure value types.
- Pasteboard, AppleScript, and `Process` are the three "outside world" surfaces — keep new I/O of that kind inside the existing bridge enums (`FinderBridge`, `TerminalBridge`, `AgentLauncher`) rather than scattered through controllers.
- Bundle identifier `io.github.bhino50.FinderPath` is used as the telemetry subsystem in `build_and_run.sh telemetry`. Keep them in sync if the bundle ID changes.

## Related directories

- `download-site/` — separate static landing page (HTML/CSS, `vercel.json`). Independent from the app build; do not assume changes here affect the macOS target.
- `.codex/environments/` — Codex CLI environment config, not consumed by the app at runtime.
