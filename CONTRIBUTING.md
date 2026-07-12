# Contributing to FinderPath

Thanks for your interest in contributing. FinderPath is a small, focused macOS utility — contributions that keep it lightweight and polished are very welcome.

---

## Filing an Issue

Before opening an issue, search existing ones to avoid duplicates.

**For bugs**, include:
- macOS version
- FinderPath version (or commit hash if building from source)
- Steps to reproduce
- What you expected vs. what happened
- Any relevant error message shown in the path header

**For feature requests**, describe the problem you are trying to solve and why the current behavior is not sufficient.

---

## Submitting a Pull Request

1. Fork the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```

2. Make your changes. See the build and test steps below.

3. Commit using conventional commit messages:
   ```
   feat: add option to copy path as file URL
   fix: handle Finder windows on external volumes
   docs: update permissions section in README
   ```

4. Push to your fork and open a pull request against `main`. Describe what the PR changes and why.

---

## Code Style

- Match the existing Swift style: `@MainActor` UI types, early returns, named constants for `UserDefaults` keys
- Keep app logic in the focused source files under `FinderPath/`; discuss larger architectural splits in an issue first
- No external Swift packages — keep the project dependency-free
- Prefer `let` over `var`; avoid force-unwrapping
- Keep functions focused and short

---

## Building and Testing

Run the dependency-free logic tests and then launch the app for manual checks:

```bash
# Test version comparison, shell quoting, and SSH target parsing
./script/test_logic.sh

# Build and launch the debug app
./script/build_and_run.sh

# Verify the app is running after launch
./script/build_and_run.sh --verify

# Stream logs while testing
./script/build_and_run.sh --logs
```

Before submitting a PR, manually verify:

- The menu opens and shows the correct path for the frontmost Finder window
- Copy Path and Copy cd Command produce the correct clipboard content
- Open in Terminal lands in the right folder
- Settings changes take effect immediately (no restart needed)
- The app does not crash or hang when Finder has no open windows
- The app handles Automation permission denial gracefully (shows error text, does not crash)

---

## Security

Please do not post security details publicly. See [SECURITY.md](SECURITY.md) for private reporting guidance.

## Code of Conduct

Be respectful and constructive. Harassment of any kind will not be tolerated. If you experience or witness unacceptable behavior, open an issue with enough context for the maintainer to review it.
