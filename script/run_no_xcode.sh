#!/usr/bin/env bash
# Build and run FinderPath WITHOUT the Xcode IDE, the .xcodeproj, or xcodebuild.
#
# It compiles the Swift sources directly with `swiftc` and assembles the
# .app bundle by hand. This still needs the Swift toolchain, which ships with the
# lightweight "Command Line Tools for Xcode" (`xcode-select --install`) — you do
# NOT need the full Xcode app open or installed for this path.
#
# Usage:
#   ./script/run_no_xcode.sh            # build, then launch
#   ./script/run_no_xcode.sh build     # build only
#   ./script/run_no_xcode.sh verify    # build, launch, confirm it stays running
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC_DIR="$ROOT_DIR/FinderPath"
SRCS=("$SRC_DIR"/*.swift "$SRC_DIR"/Terminal/*.swift)
PLIST_TEMPLATE="$ROOT_DIR/Info.plist"
PBXPROJ="$ROOT_DIR/FinderPath.xcodeproj/project.pbxproj"

APP_NAME="FinderPath"
BUNDLE_ID="io.github.bhino50.FinderPathDev"
BUILD_DIR="$ROOT_DIR/.build/no-xcode"
APP="$BUILD_DIR/$APP_NAME.app"
APP_EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
DEPLOYMENT_TARGET="13.0"
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
  [[ -f "$APP/Contents/Info.plist" ]] || {
    echo "Built app is missing Info.plist: $APP" >&2
    return 1
  }
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" || return 1
  actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" || return 1
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

# Pull version numbers from the project file so the bundle stays in sync.
read_setting() { grep -m1 "$1" "$PBXPROJ" | sed -E "s/.*$1 = ([^;]+);.*/\1/" | tr -d ' '; }
MARKETING_VERSION="$(read_setting MARKETING_VERSION || echo 0)"
CURRENT_PROJECT_VERSION="$(read_setting CURRENT_PROJECT_VERSION || echo 1)"

# Detect the host architecture so this works on Apple Silicon and Intel.
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos$DEPLOYMENT_TARGET"

# Newer SDKs implement SwiftUI property wrappers (@State, @AppStorage, ...) as
# compiler macros, but the Command Line Tools toolchain does not ship
# libSwiftUIMacros.dylib. Borrow the macro plugin directory from a full Xcode
# install when one is available; older toolchains ignore the extra search path.
SWIFTUI_PLUGIN_FLAGS=()
for DEV_DIR in "${DEVELOPER_DIR:-}" \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer; do
  PLUGIN_DIR="$DEV_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
  if [[ -n "$DEV_DIR" && -f "$PLUGIN_DIR/libSwiftUIMacros.dylib" ]]; then
    SWIFTUI_PLUGIN_FLAGS=(-plugin-path "$PLUGIN_DIR")
    break
  fi
done

# Never rewrite or re-sign the executable bundle while this exact build is
# mapped by a live process. In-place replacement can crash the app or leave it
# running with a mixture of old code and new resources; `build` mode needs the
# same preflight as the launch modes.
echo "==> Stopping an existing development build before replacing it"
terminate_exact_executable "$APP_EXECUTABLE"

echo "==> Compiling $APP_NAME with swiftc (target $TARGET, no xcodebuild)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -parse-as-library lets the sources use the @main attribute without a main.swift.
swiftc -parse-as-library -O \
  "${SRCS[@]}" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -framework SwiftUI -framework AppKit \
  -target "$TARGET" \
  ${SWIFTUI_PLUGIN_FLAGS[@]+"${SWIFTUI_PLUGIN_FLAGS[@]}"}

echo "==> Writing Info.plist (substituting build variables)"
sed \
  -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
  -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
  -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
  -e "s/\$(CURRENT_PROJECT_VERSION)/$CURRENT_PROJECT_VERSION/g" \
  "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing (with Apple Events entitlement)"
codesign --force --entitlements "$ROOT_DIR/FinderPath.entitlements" --sign - "$APP" >/dev/null
verify_built_app

if [[ "$MODE" == "build" ]]; then
  echo "Built $APP (version $MARKETING_VERSION). Launch it with: open -n \"$APP\""
  exit 0
fi

echo "==> Launching"
terminate_exact_executable "$APP_EXECUTABLE"
sleep 1
/usr/bin/open -n "$APP"

if [[ "$MODE" == "verify" ]]; then
  sleep 2
  if exact_executable_is_running "$APP_EXECUTABLE"; then
    echo "$APP_NAME development build is running from $APP_EXECUTABLE (version $MARKETING_VERSION)."
  else
    echo "$APP_NAME failed to stay running." >&2
    exit 1
  fi
fi
