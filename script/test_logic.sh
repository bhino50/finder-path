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
  "$ROOT_DIR/FinderPath/BoundedProcessRunner.swift" \
  "$ROOT_DIR/FinderPath/Bridges.swift" \
  "$ROOT_DIR/FinderPath/FinderPathStateLogic.swift" \
  "$ROOT_DIR/FinderPath/HoverPickerLogic.swift" \
  "$ROOT_DIR/FinderPath/PendingURLQueue.swift" \
  "$ROOT_DIR/FinderPath/Preferences.swift" \
  "$ROOT_DIR/FinderPath/RecentPaths.swift" \
  "$ROOT_DIR/FinderPath/RemoteServers.swift" \
  "$ROOT_DIR/FinderPath/SizeLimitedDownload.swift" \
  "$ROOT_DIR/FinderPath/TerminalLaunchCommand.swift" \
  "$ROOT_DIR/FinderPath/UpdateInstaller.swift" \
  "$ROOT_DIR/FinderPath/UpdateLeftoverCleanup.swift" \
  "$ROOT_DIR/FinderPath/VersionLogic.swift" \
  "$ROOT_DIR/Tests/LogicTests.swift" \
  -framework AppKit \
  -o "$TEST_BINARY"

"$TEST_BINARY"

# Process lifecycle tests run in their own binary because they use deliberately
# slow and TERM-resistant shell fixtures that do not belong in the pure logic
# test entry point.
PROCESS_RUNNER_TEST_BINARY="$BUILD_DIR/BoundedProcessRunnerTests"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "$ROOT_DIR/FinderPath/BoundedProcessRunner.swift" \
  "$ROOT_DIR/Tests/BoundedProcessRunnerTests.swift" \
  -o "$PROCESS_RUNNER_TEST_BINARY"

"$PROCESS_RUNNER_TEST_BINARY"

# Update downloads stream from a URLProtocol stub, so size limits, redirects
# and response checks are exercised without network access.
UPDATE_DOWNLOAD_TEST_BINARY="$BUILD_DIR/UpdateDownloadTests"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "$ROOT_DIR/FinderPath/BoundedProcessRunner.swift" \
  "$ROOT_DIR/FinderPath/Bridges.swift" \
  "$ROOT_DIR/FinderPath/RemoteServers.swift" \
  "$ROOT_DIR/FinderPath/SizeLimitedDownload.swift" \
  "$ROOT_DIR/FinderPath/UpdateInstaller.swift" \
  "$ROOT_DIR/FinderPath/VersionLogic.swift" \
  "$ROOT_DIR/Tests/UpdateDownloadTests.swift" \
  -framework AppKit \
  -o "$UPDATE_DOWNLOAD_TEST_BINARY"

"$UPDATE_DOWNLOAD_TEST_BINARY"

# Launcher discovery must leave the main actor responsive and reject obsolete
# asynchronous menu results when command preferences change. The Terminal
# launch line is also run in every available login shell.
LAUNCHER_TEST_BINARY="$BUILD_DIR/LauncherAvailabilityTests"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "$ROOT_DIR/FinderPath/BoundedProcessRunner.swift" \
  "$ROOT_DIR/FinderPath/Bridges.swift" \
  "$ROOT_DIR/FinderPath/RemoteServers.swift" \
  "$ROOT_DIR/FinderPath/TerminalLaunchCommand.swift" \
  "$ROOT_DIR/Tests/LauncherAvailabilityTests.swift" \
  -framework AppKit \
  -o "$LAUNCHER_TEST_BINARY"

"$LAUNCHER_TEST_BINARY"

# Menu-building path logic must never stat a saved folder, which may be on a
# stalled network volume. A DYLD interposer counts metadata calls on marker
# paths; the binary fails on its own if the interposer is not loaded.
CLANG="${CLANG:-$(command -v clang)}"
PROBE_COUNTER_LIBRARY="$BUILD_DIR/libMetadataProbeCounter.dylib"
"$CLANG" \
  -dynamiclib \
  -O2 \
  -target "$TARGET" \
  "$ROOT_DIR/Tests/Support/MetadataProbeCounter.c" \
  -o "$PROBE_COUNTER_LIBRARY"

NO_STAT_TEST_BINARY="$BUILD_DIR/RecentPathsNoStatTests"
"$SWIFTC" \
  -parse-as-library \
  -O \
  -target "$TARGET" \
  "$ROOT_DIR/FinderPath/Preferences.swift" \
  "$ROOT_DIR/FinderPath/RecentPaths.swift" \
  "$ROOT_DIR/Tests/RecentPathsNoStatTests.swift" \
  -framework AppKit \
  -o "$NO_STAT_TEST_BINARY"

DYLD_INSERT_LIBRARIES="$PROBE_COUNTER_LIBRARY" "$NO_STAT_TEST_BINARY"

# Terminal emulator logic tests build as a second binary so the terminal
# subsystem's UI-free files stay covered without linking the whole app.
TERMINAL_TEST_BINARY="$BUILD_DIR/FinderPathTerminalTests"
TERMINAL_SRCS=()
for CANDIDATE in \
  "$ROOT_DIR/FinderPath/Terminal/TerminalTypes.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalParser.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalScreen.swift" \
  "$ROOT_DIR/FinderPath/Terminal/TerminalInputEncoder.swift" \
  "$ROOT_DIR/FinderPath/BoundedProcessRunner.swift" \
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

# The release path's manifest updater is Python, and `bash -n` cannot see
# inside a here-document. Execute it against fixtures so a broken release
# script fails here rather than after a full Apple notarization round trip.
/usr/bin/python3 "$ROOT_DIR/script/test_release_manifest.py"

# Packaging failures and repeated versions must preserve previous artifacts.
/bin/bash "$ROOT_DIR/script/test_packaging_safety.sh"
