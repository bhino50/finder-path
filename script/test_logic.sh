#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/logic-tests"
TEST_BINARY="$BUILD_DIR/FinderPathLogicTests"

mkdir -p "$BUILD_DIR"

SWIFTC="${SWIFTC:-$(command -v swiftc)}"
TARGET="$(uname -m)-apple-macos13.0"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "$ROOT_DIR/FinderPath/Bridges.swift" \
  "$ROOT_DIR/FinderPath/RemoteServers.swift" \
  "$ROOT_DIR/FinderPath/VersionLogic.swift" \
  "$ROOT_DIR/Tests/LogicTests.swift" \
  -framework AppKit \
  -o "$TEST_BINARY"

"$TEST_BINARY"

# Terminal emulator logic tests build as a second binary so the terminal
# subsystem's UI-free files stay covered without linking the whole app.
TERMINAL_TEST_BINARY="$BUILD_DIR/FinderPathTerminalTests"
TERMINAL_SRCS=()
for CANDIDATE in \
  "$ROOT_DIR/FinderPath/Terminal/TerminalTypes.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalParser.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalScreen.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalInputEncoder.swift" \
  "$ROOT_DIR/FinderPath/Terminal/PTYProcess.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalSession.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalSessionStore.swift"; do
  [[ -f "$CANDIDATE" ]] && TERMINAL_SRCS+=("$CANDIDATE")
done

"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "${TERMINAL_SRCS[@]}" \
  "$ROOT_DIR/Tests/TerminalLogicTests.swift" \
  -framework AppKit \
  -o "$TERMINAL_TEST_BINARY"

"$TERMINAL_TEST_BINARY"
