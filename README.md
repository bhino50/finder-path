# FinderPath

**See and copy your current Finder folder path from the macOS menu bar.**

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## What it does

FinderPath sits in your menu bar and shows the POSIX path of the frontmost Finder window. Click the icon to copy the path, jump to Terminal, or launch a CLI agent (Codex, Claude) directly in that folder — no more hunting through Finder or typing paths by hand.

---

## Features

- **Menu bar path display** — always-visible path header at the top of the menu
- **Copy Path** — copies the full POSIX path to the clipboard
- **Copy cd Command** — copies a shell-safe `cd "/path/to/folder"` command, ready to paste
- **Open in Terminal** — opens Terminal.app in the current Finder folder
- **Open with Codex / Open with Claude** — launches optional CLI agents in a new Terminal session at the current folder
- **Configurable Settings** — toggle menu items; choose path display style (full, `~`-abbreviated, compact); adjust header width, font size, and truncation mode; pick menu bar icon and optional short title; set `cd` quoting style; configure agent executable paths

---

## Screenshot

![FinderPath menu bar screenshot](download-site/assets/finderpath-icon.png)

---

## Quick Start

### Download (recommended)

Download the latest `.dmg` from [Releases](https://github.com/bhino50/finder-path/releases), open it, drag `FinderPath.app` to `/Applications`, and launch it. The app is menu bar-only — no Dock icon will appear.

### Build from Source

Requirements: macOS 13+, Xcode with Swift 5.9+

```bash
git clone https://github.com/bhino50/finder-path.git
cd finder-path
open FinderPath.xcodeproj   # then press Run in Xcode
```

Or build and launch from the terminal:

```bash
./script/build_and_run.sh
```

---

## Settings

Open Settings from the menu (or press `,` while the menu is open) to configure:

| Section | Options |
|---------|---------|
| Menu Items | Toggle visibility of each menu action |
| Path Header | Header title, display style, truncation, width, font size |
| Menu Bar Icon | SF Symbol choice, optional short title |
| Terminal | `cd` quoting style (double or single quotes) |
| Agent Launchers | Codex and Claude executable paths, hide-if-unavailable toggle |

---

## Permissions

FinderPath requires two Automation permissions, granted via a macOS prompt on first use:

- **Finder** — reads the path of the frontmost Finder window via AppleScript
- **Terminal** — opens Terminal sessions for the "Open with Codex/Claude" actions

To review or re-grant permissions: System Settings > Privacy & Security > Automation > FinderPath.

If access is denied, FinderPath shows the AppleScript error in the path field instead of crashing.

---

## Building and Packaging

```bash
# Debug build + run
./script/build_and_run.sh

# Local-test DMG (unsigned, for personal use)
./script/package_release.sh

# Signed + notarized release (requires Apple Developer account)
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="FinderPathNotary" \
./script/package_release.sh
```

See the `script/` folder for full details. For Developer ID signing and notarization setup, store your credentials once with `xcrun notarytool store-credentials` before running the release script.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

---

## License

MIT — see [LICENSE](LICENSE).
