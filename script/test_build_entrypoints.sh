#!/usr/bin/env bash
# Usage mistakes must not stop an app, build, or launch anything.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/finderpath-entrypoint-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
CASES=0

for script in build_and_run.sh run_no_xcode.sh; do
  fixture="$WORK_DIR/$script"
  mkdir -p "$fixture/script"
  cp "$ROOT_DIR/script/$script" "$fixture/script/$script"
  for scenario in invalid extra help short-help; do
    case "$scenario" in
      invalid) args=(--not-a-mode); expected=2 ;;
      extra) args=(run unexpected); expected=2 ;;
      help) args=(--help); expected=0 ;;
      short-help) args=(-h); expected=0 ;;
    esac
    status=0
    DEVELOPER_DIR="$WORK_DIR/missing-xcode" /bin/bash "$fixture/script/$script" \
      "${args[@]}" > "$fixture/output.log" 2>&1 || status=$?
    if [[ "$status" != "$expected" ]] || \
        ! /usr/bin/grep -q '^usage: ' "$fixture/output.log" || \
        [[ "$(wc -l < "$fixture/output.log" | tr -d ' ')" != 1 ]] || \
        [[ -e "$fixture/.build" ]]; then
      echo "FAIL: $script $scenario reached side effects or returned the wrong status" >&2
      cat "$fixture/output.log" >&2
      exit 1
    fi
    CASES=$((CASES + 1))
  done
done

echo "Build entrypoint tests passed ($CASES scenarios)."
