# FinderPath audit and repairs — September 8, 2026

**Source repairs, independent review, tests, notarization, and installation of 1.9.2 are complete. Final native verification is pending unlock.** The Mac locked during native testing. The previously active Hermes process had exited by the pre-install check; FinderPath was stopped only after verifying it had zero terminal child processes.

The audit began from clean `main` at `f6b52e7cdc6b1802f2e6eff21274c143dfb34b23` in the canonical FinderPath checkout. Repairs are on `fix/finderpath-audit-2026-09-08`, preparing **1.9.2 / build 12**. The initial installation was **1.9.1 / build 11**, Developer ID signed and notarized, at `/Applications/FinderPath.app`. The verified replacement is now **1.9.2 / build 12**, running from the same path. The host is Apple silicon running macOS 27.0.

Fable was not an available model in this Codex session. Three delegated audit/implementation areas and a fresh independent final reviewer used the supported **GPT-6 Astra at max**. No claim is made that the active parent session was switched to Fable or to a different reasoning setting.

The source review covered Finder queries and action targets, app lifecycle and URL handoff, menus and launchers, preferences and login items, remote server selection and SSH construction, recent-path/session persistence, terminal parser/screen/input/selection/PTY lifecycle, update download/extraction/verification/replacement, and build/release tooling. The independent final review found no actionable introduced defects in the completed patch.

## Repaired findings

| Area | Verified failure or source-supported defect | Repair and evidence |
| --- | --- | --- |
| Process execution | Embedded NULs were silently truncated by POSIX argument handling; unrelated file descriptors reached children. Wall-clock movement could affect deadlines. | Reject NUL executable/argument values, close unrelated descriptors on spawn, and use a monotonic deadline. Three baseline failures were reproduced; process suite now passes 50 assertions. |
| Updater subprocesses | A 0.1-second timeout took 3.01 seconds when a child retained stderr. Several update commands had no deadline, and diagnostics grew without a bound. | Use the shared bounded runner for update tools, including descendant cleanup and capped diagnostics. The inherited-pipe reproduction now fails in approximately 1.1 seconds including cleanup grace. |
| Extraction safety | A quota violation could be lost when the terminated extractor exited zero. Special files could proceed to later copying/verification. | Preserve explicit monitor failure, reject unsupported file types and app-named symlinks/files, cap top-level enumeration, and bound DMG detach on failure paths. Temporary archive fixtures cover these outcomes. |
| Update replacement | Copying at the final application path exposed a partial replacement; failed recovery could remove the only complete remaining app. Relaunch helpers could wait indefinitely. | Prepare and verify a private copy on the destination volume before renaming; retain a recovery bundle; preserve a remaining complete replacement when backup recovery fails; bound relaunch waiting. Production transaction functions are exercised with temporary app directories and injected failures. |
| Update requests | Concurrent installations could overlap. Final-URL-only validation permitted an unsafe intermediate redirect, and resource download duration was not explicitly bounded. | Serialize installs, reject unsafe redirects before following them, disallow credential-bearing URLs, and bound request/resource time. Network redirect behavior is source-reviewed rather than exercised against a hostile server. |
| Version verification | Oversized numbers became zero; `1..9` could equal `1.9`; numbers inside prerelease suffixes affected numeric version order. | Compare normalized decimal components without integer overflow, reject malformed numeric cores, and preserve the full suffix for equivalence. Regression fixtures cover all three reproduced errors. |
| URL queue | Once the startup queue was full, the loop continued visiting the rest of an incoming batch. | Append only the remaining prefix, preserving earliest URLs and bounded queue work. |
| Menu and launcher responsiveness | Agent and cmux executable checks could perform filesystem work on the main actor, including paths on stalled volumes. | Bounded background probes, shared request coalescing/cache, capped concurrency, and generation-checked menu results. Action-time lookup also leaves the main actor. The new launcher suite passes 23 assertions, including delayed/stale requests. |
| Shell override | App launch configuration synchronously checked the override's executable bit on the main actor and silently substituted another shell for invalid overrides. | Pass an explicit override to the existing background PTY launch path, which reports a launch failure. |
| Remote connection direction | A status refresh during a Disconnect confirmation could cause the eventual action to recompute as Connect. | Carry an explicit enabled/disabled action through the confirmation. |
| Remote connection target | A selected device's cached hostname could become stale after refresh; filtering a device out could leave its Connect action enabled. | Resolve the target from current visible rows, disable missing targets, and invalidate saved-server index selections after list changes. Regression cases cover renamed, filtered, removed, unnamed, and invalid selections. |
| Login items | `.requiresApproval` was treated as unregistered, pending registrations could skip unregister, and the UI did not consistently read back successful changes. | Bind the toggle to actual service status, show approval guidance, unregister pending registrations, and refresh on activation. Reading status no longer triggers a registration write. |
| Copy cd Command | Interactive shells expand `!` inside double quotes, breaking otherwise valid folder paths. | Fall back to the existing single-quote encoder for bang-containing paths, preserving apostrophes and other literal characters. |
| Terminal SGR | Extra/malformed colon color parameters escaped their group and consumed or applied neighboring attributes. | Keep subparameters scoped to their color group and preserve later independent attributes. |
| Streamed Unicode | Variation selectors and keycap components arriving at a margin could be dropped, producing a different grapheme from an unsplit input. | Preserve the complete streamed grapheme at the right edge, including when wrap is disabled. |
| Terminal resize | The primary screen's saved cursor did not follow retained rows when resized, unlike the parked-primary path. | Translate saved cursor positions consistently during resize. |
| Selection and naming | Selection endpoints on a wide glyph's continuation cell could omit the glyph; confirming an automatic fallback name did not pin the user's naming intent. | Share complete-glyph column ranges between highlighting/copy; persist explicit naming intent even when the visible fallback text is unchanged. |
| Redraw recovery | A directly attached test view could miss the first visibility notification. Fully occluded windows intentionally pause redraw, so stale background captures are not proof of a production rendering defect. | Reevaluate the view's existing visibility-based redraw gate when PTY output arrives. The corrected harness also performs production's post-show timer setup and status-change invalidation. Final foreground verification is pending unlock. |
| Packaging recovery | A failed build erased earlier release files and their evidence from `dist`; repeating a version destroyed its previous artifact. | Preserve `dist` and reject existing artifact names before installing the cleanup trap. Six before-fix failures now pass in two isolated packaging scenarios. |

The terminal suite grew from 429 to 463 assertions. Before repairs, the parser/grapheme/cursor batch reproduced 20 failed assertions and selection/naming reproduced seven. The source was frozen before packaging; recorded hashes confirm no production build input changed during packaging.

## Executed verification

| Check | Result |
| --- | --- |
| Baseline suites | 657 assertions and six manifest cases passed |
| Final general logic | 246 assertions passed |
| Bounded processes | 50 assertions passed |
| Launcher responsiveness/cache | 23 assertions passed |
| Terminal logic/lifecycle | 463 assertions passed |
| Manifest / packaging fixtures | Six cases and two scenarios passed |
| Total final assertions | **782**, plus eight manifest/packaging scenarios |
| Direct Swift application build | Passed; development bundle identifier verified |
| Xcode 27 Debug build | Passed |
| Universal Release build | Passed; `x86_64 arm64` verified |
| Project/shell/Python syntax and diff whitespace | Passed |
| Independent final source review | No actionable introduced defects found |
| App and DMG trust | Developer ID signature, Apple notarization, stapled ticket, and Gatekeeper acceptance passed |
| Final ZIP and mounted DMG contents | Exact app identity/version/signature verified by package tooling |
| Existing app rollback copy | Copied and strict signature verified |
| Installed 1.9.2 | Identity/build, pinned signature, Gatekeeper, exact executable hash, and running process verified |

The default Xcode installation stalled before compiling application source during its Clang macro probe. Only that owned build was stopped. Subsequent builds used `/Applications/Xcode-beta.app/Contents/Developer` through a per-command `DEVELOPER_DIR`; global Xcode selection was preserved.

Primary commands were `./script/test_logic.sh`, `./script/run_no_xcode.sh build`, Xcode Debug build with `CODE_SIGNING_ALLOWED=NO`, and `./script/package_release.sh` using existing Developer ID and App Store Connect credentials. Secret values are not included in this report.

## Native observations and remaining gates

The isolated native harness uses the real `TerminalView`, `TerminalSession`, parser/screen/PTY implementation, and Settings/Connections controller classes. It uses a separate bundle ID and a clean audit shell. It does not load or persist the installed app's terminal sessions or recent paths. It bypasses the production status menu, terminal panel/session-store lifecycle, app election, and app termination delegate; its evidence is limited accordingly.

Observed through native accessibility and window captures:

- ASCII commands executed and returned their output.
- Pasted CJK text, heart/keycap emoji, and red/normal text rendered after a foreground resize. Native `typeText` dropped some Unicode; clipboard paste reached the terminal despite the automation tool reporting a read-acknowledgment timeout.
- The production Settings window opened with the expected controls and installed agent paths, without altering the real app's preferences or login registration.

The harness was corrected to match production post-show redraw/status wiring and rebuilt. The Mac then locked, preventing the final foreground pass. Stale captures of occluded windows are explicitly excluded from the defect evidence.

**Required before calling the installed app fully verified:** unlock the Mac and exercise the production Finder path menu, terminal panel/show-hide/resize/selection, Settings, and connection selection. The actual installed identity and running process have already been verified. Actual in-app automatic installation and relaunch have not been exercised against a signed release; transaction fixtures and package verification do not substitute for that end-to-end result.

## Prepared artifacts and recovery

| Artifact | SHA-256 |
| --- | --- |
| `dist/FinderPath-1.9.2.dmg` | `7bf9c23decc45ad6545c7991fd41cf71010348d6709bb8f9f70c3526e6e92724` |
| `dist/FinderPath-1.9.2-macOS13-notarized.zip` | `34e2859c9f34b72f3e492ee8abf367feb1f84f144167f9013db23d0bb9d50a49` |

App notarization submission: `d4dbfd01-1d5d-4c8b-8ac7-40af1fda317b`. DMG submission: `551bff9e-56d0-4f78-b135-8e6fadeaedd5`.

The recovery bundle is `/Users/brandon/FinderPath-1.9.1-backup-20260908.app`. After the Hermes process had exited, a fresh child-process check returned zero. The signed replacement was copied into a private staging directory on the Applications volume and reverified before the old app was stopped. The complete bundles were exchanged by rename. Installed 1.9.2 passed pinned signature and Gatekeeper checks; its executable hash matches the notarized release, and Launch Services started it successfully. This was a verified manual replacement; the final native workflow pass remains pending unlock. The new artifacts are local; no GitHub release was published. Packaging's local download-metadata update was restored to the prior 1.9.1 contents after verifying that only the expected generated changes were present.

Detailed local evidence is retained in:

- `.build/audit-20260908-tests-final.log`
- `.build/audit-20260908-debug-final.log`
- `.build/audit-20260908-direct-build-final.log`
- `.build/audit-20260908-package-1.9.2.log`
- `.build/audit-20260908/release-verification-1.9.2.json`
- `.build/audit-20260908/installed-verification-1.9.2.json`
- `.build/audit-20260908/source-hashes-before-package.json`
- `.build/audit-20260908/terminal/`
- `.build/updater-audit-20260908/`
- `.build/audit-20260908/native/`
- `.build/audit-20260908-packaging-before.log`
