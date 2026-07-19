# Security Policy

## Supported Versions

Security fixes are applied to the latest release on GitHub.

## App Sandbox

FinderPath intentionally does not enable App Sandbox because its core features
launch interactive PTY shells, open user-selected terminal applications, and
send Apple Events to Finder. Release builds instead use the hardened runtime,
Developer ID signing, and Apple notarization. Keep shell access and Finder
Automation permission enabled only when those features are needed.

## Reporting a Vulnerability

Please report security issues privately through GitHub Security Advisories for this repository. If advisories are unavailable, open a minimal issue that says you need to report a security vulnerability and avoid posting exploit details publicly.

Useful details include:

- FinderPath version or commit hash
- macOS version
- Steps to reproduce
- Impact and affected workflow

The maintainer will review reports as time allows and coordinate a fix before public disclosure when the issue is confirmed.
