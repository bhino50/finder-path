# FinderPath

**Stack:** Swift 5.9+ / AppKit / macOS 13+ | **No external dependencies**

## What

Lightweight macOS menu bar utility. Reads the POSIX path of the frontmost Finder window via AppleScript and exposes copy, `cd` command, Terminal launch, and AI agent launch actions through an `NSStatusItem` native menu.

## Build Commands

```bash
# Build debug + launch (primary dev loop)
./script/build_and_run.sh

# Additional modes
./script/build_and_run.sh --debug      # Attach lldb
./script/build_and_run.sh --logs       # Stream os_log output
./script/build_and_run.sh --verify     # Assert process is running

# Release packaging
./script/package_release.sh            # Unsigned local-test DMG

# Signed + notarized (requires DEVELOPER_ID and NOTARY_PROFILE env vars)
DEVELOPER_ID="Developer ID Application: ..." \
NOTARY_PROFILE="FinderPathNotary" \
./script/package_release.sh

# Open in Xcode
open FinderPath.xcodeproj
```

## Architecture

```
FinderPath/
  FinderPathApp.swift      # Single source file — entire application
FinderPath.xcodeproj/
  project.pbxproj          # Xcode project config, signing, build settings
Info.plist                 # LSUIElement=YES, NSAppleEventsUsageDescription
script/
  build_and_run.sh         # xcodebuild debug wrapper
  package_release.sh       # Release build, codesign, notarize, DMG
download-site/             # Static landing page (Vercel)
```

All application logic lives in `FinderPath/FinderPathApp.swift`. The file is large by design — one self-contained Swift file with no module split.

**Data flow:** `StatusItemController` owns the `NSStatusItem`. On click it calls `FinderPathState.refresh()`, which calls `FinderBridge.currentPath()`. `FinderBridge` runs an `NSAppleScript` query against Finder and returns the POSIX path string. `StatusItemController.rebuildMenu()` then populates the `NSMenu` from preferences and the current path. Settings are stored in `UserDefaults` via `FinderPathPreferences` and observed with `NotificationCenter`.

## Key Files

```
FinderPath/FinderPathApp.swift          # Everything: AppDelegate, StatusItemController,
                                        #   FinderPathState, FinderBridge, TerminalBridge,
                                        #   AgentLauncher, ShellCommand, FinderPathPreferences,
                                        #   SettingsView, PathMenuHeaderView
Info.plist                              # App metadata, privacy strings, LSUIElement
FinderPath.xcodeproj/project.pbxproj   # Build settings, signing, capabilities
script/build_and_run.sh                 # Dev build and launch
script/package_release.sh              # Release pipeline
```

## Conventions

- Swift 5.9+, macOS 13 deployment target
- No external Swift packages or frameworks — pure AppKit + SwiftUI (Settings window only)
- `@MainActor` on all UI-touching classes; `NSAppleScript` runs synchronously on the main actor
- App Sandbox is **disabled** to keep the Finder AppleScript bridge simple
- Hardened Runtime is enabled on Release builds (required for notarization)
- `NSStatusItem` with `variableLength`; menu rebuilt from scratch on every click

## Do Not Touch

- Never hardcode signing identities or notary credentials — always pass via `DEVELOPER_ID` and `NOTARY_PROFILE` environment variables
- Do not re-enable App Sandbox without also adding the `com.apple.security.automation.apple-events` entitlement and testing the Automation permission flow end-to-end
- The bundle ID `io.github.bhino50.FinderPath` is referenced in `build_and_run.sh` — keep it in sync with `project.pbxproj`
