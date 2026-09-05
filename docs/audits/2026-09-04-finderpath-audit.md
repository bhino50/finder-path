# FinderPath reliability audit — September 4, 2026

Scope: local source audit and repairs based on `main` at `0dcf016`. Work is on
`fix/finderpath-audit-2026-09-04`. The starting checkout was clean. The installed
application was FinderPath 1.9 (build 10), running from `/Applications/FinderPath.app`
on Apple silicon with macOS 27.0.

The audit reviewed Finder path refresh and action validation, launch routing,
recent-path and session persistence, terminal parsing and screen lifecycle,
update verification, and build/test entry points. Four terminal reliability
problems were reproduced and repaired. This is a source and local-runtime audit,
not a certification of every external integration or release-install path.

## Fixed findings

| Finding | Effect before the repair | Result |
| --- | --- | --- |
| P2 — CSI commands lost their namespace | Intermediate-byte and unsupported DEC-private commands could execute as unrelated ANSI commands: changing scroll margins, styling, cursor state, or response bytes. Oversized commands executed their truncated prefix. | Unsupported or malformed forms are consumed without changing the screen. Overlong commands are discarded through their final byte. Supported private modes remain functional. |
| P2 — Interrupted control sequences did not recover | CAN/SUB inside OSC/DCS/CSI could swallow subsequent output. A new escape following an unfinished string or charset declaration could print control syntax. C0 controls and DEL could disrupt pending sequences. | Cancellation clears pending sequence state; fresh escapes restart parsing; embedded C0 controls execute and DEL is ignored without ending the sequence. |
| P2 — Unsupported underline colors changed other styles | `58:...` could reset existing foreground/bold. Semicolon color arguments were interpreted as reset, underline, inverse, or other independent SGR commands. | Underline-color parameters are consumed while preserving the active brush, and later supported SGR attributes still apply. |
| P2 — Selections could outlive their screen | Entering/leaving the alternate buffer or receiving RIS reused old selection/viewport anchors on unrelated text. Only session restart previously invalidated them. | Screen generation advances before notifying views on reset or a real buffer transition. Redundant mode settings and ordinary output preserve anchors. |

The protocol distinctions were checked against the primary
[XTerm control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
The repairs deliberately consume unimplemented controls rather than add new
terminal protocol features.

## Changed files

- `FinderPath/Terminal/TerminalParser.swift`: command dispatch, cancellation and
  escape recovery, bounded-sequence handling, and underline-color consumption.
- `FinderPath/Terminal/TerminalSession.swift`: screen identity notifications;
  the production PTY output application method is available to regression tests.
- `FinderPath/Terminal/TerminalView.swift`: update the anchor-lifetime comments
  to cover reset and buffer switches handled by the existing observer.
- `Tests/TerminalLogicTests.swift`: regression cases for the repaired behavior,
  including split PTY reads, observer timing, and a buffer round trip in one read.
- `FinderPath.xcodeproj/project.pbxproj`: prepare patch version 1.9.1/build 11.
- `download-site/version.json` and `download-site/index.html`: point downloads
  and update metadata to the signed, notarized 1.9.1 release.
- This audit report.

## Verification

Baseline: 185 general-logic assertions, 43 process-lifecycle assertions,
371 terminal assertions, and six release-manifest cases passed.

Before the repairs, the new tests reproduced 22 parser/style failures, seven
screen-generation failures, and two additional escape-recovery failures found
during final review. Local failure evidence is retained in
`.build/logic-tests/audit-regressions-before.txt`,
`.build/logic-tests/audit-regressions-screen-before.txt`, and
`.build/logic-tests/audit-parser-review-before.txt`.

Final verification passed after the last source changes:

| Check | Result |
| --- | --- |
| General logic | 185 assertions passed |
| Bounded process lifecycle | 43 assertions passed |
| Terminal logic and lifecycle | 429 assertions passed, including 58 added assertions |
| Release manifest | Six cases passed |
| Direct Swift app build | Passed; development bundle identifier verified |
| Xcode 27 Debug | Passed |
| Xcode 27 Release | Passed; `lipo -archs` confirmed `x86_64 arm64` |
| Diff whitespace | Passed |
| Installed copy at initial audit | Version 1.9/build 10 retained; strict code-signature validation passed |

Total: 657 assertions plus six release-manifest cases. Final logs are
`.build/logic-tests/audit-after.txt`, `.build/audit-build-no-xcode-20260904.log`,
`.build/audit-build-debug-xcode27-20260904.log`, and
`.build/audit-build-release-xcode27-20260904.log`. Xcode reported only the
App Intents metadata-extraction notice for this app without an AppIntents dependency.

Commands used:

```sh
./script/test_logic.sh
./script/run_no_xcode.sh build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FinderPath.xcodeproj -scheme FinderPath -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/AuditXcode27 \
  CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FinderPath.xcodeproj -scheme FinderPath -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/AuditXcode27 \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Xcode 26.6 stalled in its build service while running the Clang macro probe,
before compiling any application source. A process sample showed Clang blocked
in `write`; the same command completed when run directly. The owned stalled
build was stopped. Debug and universal Release builds subsequently succeeded
with the installed Xcode 27 beta (27A5194q), using a per-command developer path.
The global Xcode selection was not changed.

## Native terminal smoke check

A temporary application in `.build/FinderPathTerminalAudit.app` hosted the real
`TerminalView`, `TerminalSession`, parser, screen, and PTY implementation under a
separate bundle identifier. It did not load the installed app's saved sessions
or modify its preferences. The harness source is `.build/TerminalAuditApp.swift`.

Verified through the native UI and accessibility readback:

- Typed shell commands were executed and their output rendered.
- `RED BEFORE RED AFTER` retained matching red styling across an unsupported
  underline-color command.
- Output after an interrupted OSC printed `RECOVERED OUTPUT`.
- Entering the alternate screen showed its fixture text; returning restored
  the original shell contents.
- RIS reset redrew the terminal with the reset fixture text.

Manual drag-selection and clipboard smoke checks could not be completed:
the native automation surface returned window/capture and clipboard timeouts.
Selection invalidation is covered by the session/observer regression tests;
this report does not claim a successful manual selection-and-copy check.
The temporary shell and test app were stopped after the check.

## Initial audit delivery boundary

At the completion of the initial audit, the fixes were local source changes
and build artifacts. FinderPath 1.9 remained installed and running. The user
then requested GitHub synchronization and installation of the updated app;
version 1.9.1/build 11 contains these repairs. Packaging and installation
evidence is recorded below. The GitHub release and PR records provide the
publication and merge timestamps.

The unsigned Xcode artifacts above establish build verification. Full
Finder-menu interactions, external terminal/SSH launches, and an actual
in-place updater run were not exercised during the initial audit.

## Version 1.9.1 packaging and installation

The universal release app was built from commit
`52f6a7f13c9aeb1a0001aa8e7d491e1986637923`, tagged `v1.9.1`, using
`script/package_release.sh` with the per-command Xcode 27 developer directory.
Only the download metadata and this report changed after that source commit.

Both artifacts passed Developer ID signing, Apple notarization, stapled-ticket
validation, and Gatekeeper acceptance (`source=Notarized Developer ID`). The
package checks also verified the exact app identity inside the ZIP and DMG.

| Artifact | SHA-256 |
| --- | --- |
| `FinderPath-1.9.1.dmg` | `e668227917db00c634f63394606a9266502267c1f2f7f6f3ff15c587480b53c6` |
| `FinderPath-1.9.1-macOS13-notarized.zip` | `b9c442e864cfc6662c13432eac932bd766600024fe6c23dc8364d53d03617026` |

Apple accepted app submission `9ad169d8-d593-4db1-a4e4-f4b8d09053ad` and DMG
submission `034a65f4-01b1-462c-896e-b717e6b7d029`. The release is available at
[FinderPath 1.9.1](https://github.com/bhino50/finder-path/releases/tag/v1.9.1).
Publication precedes merging the download manifest.

On this Mac, the existing FinderPath process had no terminal child processes
before it was stopped. Version 1.9 was preserved as
`~/FinderPath-1.9-backup-20260904.app`, and the verified new bundle was installed
at `/Applications/FinderPath.app`.

Installed verification confirmed version 1.9.1/build 11, release bundle ID
`io.github.bhino50.FinderPath`, team `VJPMCBH6NX`, strict signature validity,
a valid stapled ticket, Gatekeeper acceptance, and the same executable bytes
as the release ZIP. Finder's native Get Info window showed **Version: 1.9.1**,
**Application (Universal)**, and **Macintosh HD > Applications**. Opening the
selected app in Finder launched the executable from the installed path.

This was a verified manual bundle replacement. The in-app automatic update
installation flow was not exercised. Local evidence is retained in
`.build/package-release-1.9.1.log` and
`.build/release-verification-1.9.1.json`.
