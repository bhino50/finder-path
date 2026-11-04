#!/usr/bin/env bash
# A failed or repeated package build must never erase an existing release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/finderpath-package-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILURES=0

for scenario in failed-build existing-output; do
  FIXTURE="$WORK_DIR/$scenario"
  mkdir -p "$FIXTURE/script" "$FIXTURE/FinderPath.xcodeproj" "$FIXTURE/dist"
  cp "$ROOT_DIR/script/package_release.sh" "$FIXTURE/script/package_release.sh"
  printf 'MARKETING_VERSION = 9.9;\n' > "$FIXTURE/FinderPath.xcodeproj/project.pbxproj"
  printf 'known-good release\n' > "$FIXTURE/dist/FinderPath-1.0.dmg"
  printf 'release evidence\n' > "$FIXTURE/dist/verification.json"
  if [[ "$scenario" == existing-output ]]; then
    printf 'existing candidate\n' > "$FIXTURE/dist/FinderPath-9.9-ADHOC-LOCAL-ONLY-NOT-FOR-PUBLIC-RELEASE.dmg"
  fi

  # An invalid developer directory forces a deterministic build failure before
  # Xcode can compile anything. The fixture has no signing/notary credentials.
  if env -u DEVELOPER_ID -u NOTARY_PROFILE -u NOTARY_KEY -u NOTARY_KEY_ID -u NOTARY_ISSUER \
      DEVELOPER_DIR="$WORK_DIR/missing-xcode" \
      /bin/bash "$FIXTURE/script/package_release.sh" > "$FIXTURE/output.log" 2>&1; then
    echo "FAIL: $scenario unexpectedly succeeded" >&2
    FAILURES=$((FAILURES + 1))
  fi
  if [[ "$(cat "$FIXTURE/dist/FinderPath-1.0.dmg" 2>/dev/null || true)" != "known-good release" ]]; then
    echo "FAIL: $scenario erased an earlier release" >&2
    FAILURES=$((FAILURES + 1))
  fi
  if [[ "$(cat "$FIXTURE/dist/verification.json" 2>/dev/null || true)" != "release evidence" ]]; then
    echo "FAIL: $scenario erased release evidence" >&2
    FAILURES=$((FAILURES + 1))
  fi
  if [[ "$scenario" == existing-output ]]; then
    if [[ "$(cat "$FIXTURE/dist/FinderPath-9.9-ADHOC-LOCAL-ONLY-NOT-FOR-PUBLIC-RELEASE.dmg" 2>/dev/null || true)" != "existing candidate" ]]; then
      echo "FAIL: a repeated build erased its previous artifact" >&2
      FAILURES=$((FAILURES + 1))
    fi
    if ! /usr/bin/grep -q 'Refusing to overwrite existing artifact' "$FIXTURE/output.log"; then
      echo "FAIL: a repeated build reached Xcode instead of rejecting the collision" >&2
      FAILURES=$((FAILURES + 1))
    fi
  fi
done

if (( FAILURES > 0 )); then exit 1; fi
echo "Packaging safety tests passed (2 scenarios)."
