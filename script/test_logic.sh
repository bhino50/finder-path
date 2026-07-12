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
