# FinderPath audit — November 4, 2026

## Scope and result

Reviewed the macOS application, terminal emulator and PTY lifecycle, Finder
path handling, menu launchers, remote connections, updater trust and recovery,
and build/release tooling. This audit continues the existing 1.9.3 / build 13
branch and includes its earlier unmerged fixes. The separate Linux sibling is
outside this audit.

Seven additional defects were fixed:

| Area | Defect | Repair and regression coverage |
| --- | --- | --- |
| Terminal alternate screen | Leaving a full-screen application could lose shell formatting, character sets, and pending line wrap. | Mode 1049 uses the existing complete cursor save/restore; mode 1048 is supported too. Parser-to-screen tests cover formatting, position, wrap, and repeated mode transitions. |
| Finder path bytes | Removing CRLF as Swift Characters could truncate a legal folder name. | Strip precisely the one LF scalar emitted by osascript; preserve CR and CRLF in path names. |
| Compact path header | An empty loading path resolved to the application's working directory. | Keep the empty value so the existing loading placeholder appears; test all three display styles. |
| Built-in agent launches | POSIX-only quoting changed unusual executable names in supported non-POSIX shells. | Use the existing portable argument encoder; execute fixtures with quotes, backslashes, and history characters in installed shells. |
| Tailscale discovery | Filesystem checks could block before the CLI's timeout began. | Resolve the executable with the existing asynchronous bounded launcher worker, including regular-file validation and the bundled app fallback. |
| Update versions | Empty prerelease/build identifiers and repeated metadata separators were accepted. | Validate each suffix identifier; test rejected manifests, valid hyphens, and the streamed update-check path. |
| Build entrypoints | Invalid arguments or help could stop a development app; the no-Xcode script could launch on a typo. | Validate modes before side effects, add help, and add Xcode build-only mode. Eight isolated entrypoint scenarios verify early exits. |

## Verification

- Full `./script/test_logic.sh`: **1,131 assertions** across six Swift binaries
  (333 core, 54 process, 25 update download, 116 launcher, 12 no-stat, 591 terminal).
- Release-manifest fixtures: **6 cases passed**.
- Packaging preservation fixtures: **2 scenarios passed**.
- Build-entrypoint fixtures: **8 scenarios passed**.
- Xcode Release build: passed; executable contains **arm64 and x86_64**.
- Command-Line-Tools build: passed; development bundle identity verified.
- Shell fixtures executed under sh, bash, zsh, dash, and tcsh. Fish was not
  installed on the test host.
- Terminal and malformed-version regressions were also run against the old
  implementation and failed before their fixes.
- Independent code review of the integrated changes and security review of
  the prior unmerged updater/process/terminal changes found no actionable
  defects. `git diff --check` and plist validation passed.

Xcode emitted its App Intents metadata-extraction warning because this app
does not depend on AppIntents. No Swift compiler warnings were observed.

## Practical limits

Native UI inspection encountered a Computer Use transport timeout. This audit
therefore does not claim current visual acceptance of the menu, clipboard,
Settings, input methods, or an actual remote-server connection. Regression
tests and successful builds do not substitute for those native checks.

The download manifest remains on public version 1.9.1. A source update is
separate from a downloadable release: new public ZIP/DMG artifacts require a
successful Developer ID signing, Apple notarization, and artifact verification
run. No unnotarized artifact should be uploaded as a public release.
