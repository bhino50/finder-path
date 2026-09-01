#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT_PATH="$ROOT_DIR/FinderPath.xcodeproj"
SCHEME="FinderPath"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="$ROOT_DIR/.build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/FinderPath.app"
APP_NAME="FinderPath"
BUNDLE_ID="io.github.bhino50.FinderPathDev"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
HOST_ARCH="$(uname -m)"
MODE="${1:-run}"

matching_executable_pids() {
  local expected_executable="$1"
  local line trimmed pid executable
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    pid="${trimmed%%[[:space:]]*}"
    executable="${trimmed#"$pid"}"
    executable="${executable#"${executable%%[![:space:]]*}"}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$executable" == "$expected_executable" ]] && printf '%s\n' "$pid"
  done < <(/bin/ps -ww -axo pid=,comm=)
}

exact_executable_is_running() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && return 0
  done < <(matching_executable_pids "$1")
  return 1
}

terminate_exact_executable() {
  local executable="$1"
  local pid attempt
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(matching_executable_pids "$executable")

  for ((attempt = 0; attempt < 50; attempt++)); do
    exact_executable_is_running "$executable" || return 0
    /bin/sleep 0.1
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(matching_executable_pids "$executable")

  for ((attempt = 0; attempt < 20; attempt++)); do
    exact_executable_is_running "$executable" || return 0
    /bin/sleep 0.1
  done

  echo "Could not stop the existing development app at $executable" >&2
  return 1
}

verify_built_app() {
  local actual_bundle_id actual_executable
  [[ -f "$APP_PATH/Contents/Info.plist" ]] || {
    echo "Built app is missing Info.plist: $APP_PATH" >&2
    return 1
  }
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" || return 1
  actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")" || return 1
  [[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || {
    echo "Built app has bundle ID $actual_bundle_id; expected $BUNDLE_ID" >&2
    return 1
  }
  [[ "$actual_executable" == "$APP_NAME" && -x "$APP_EXECUTABLE" ]] || {
    echo "Built app does not contain the expected executable: $APP_EXECUTABLE" >&2
    return 1
  }
  echo "Verified development app: $BUNDLE_ID at $APP_EXECUTABLE"
}

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for developer_dir in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    if [[ -d "$developer_dir" ]]; then
      export DEVELOPER_DIR="$developer_dir"
      break
    fi
  done
fi

terminate_exact_executable "$APP_EXECUTABLE"

/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$HOST_ARCH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

verify_built_app

open_app() {
  /usr/bin/open -n "$APP_PATH"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_EXECUTABLE\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    exact_executable_is_running "$APP_EXECUTABLE"
    echo "$APP_NAME development build is running from $APP_EXECUTABLE."
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
