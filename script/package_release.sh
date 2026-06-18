#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/FinderPath.xcodeproj"
PBXPROJ="$PROJECT_PATH/project.pbxproj"
SCHEME="FinderPath"
CONFIGURATION="Release"
APP_NAME="FinderPath"

# Single source of truth: the release version is the project's MARKETING_VERSION.
VERSION="$(sed -nE 's/.*MARKETING_VERSION = ([^;]+);.*/\1/p' "$PBXPROJ" | head -n1 | tr -d ' ')"
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from $PBXPROJ" >&2
  exit 1
fi
echo "Packaging $APP_NAME version $VERSION (from MARKETING_VERSION)"

DERIVED_DATA_PATH="$ROOT_DIR/.build/PackageDerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
README_SRC="$ROOT_DIR/script/dmg-install-readme.txt"
ENTITLEMENTS="$ROOT_DIR/FinderPath.entitlements"

if [[ -d /Applications/Xcode.app/Contents/Developer && -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR"
mkdir -p "$DIST_DIR"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Building unsigned Release app for Developer ID signing..."
  /usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

  echo "Signing with Developer ID: $DEVELOPER_ID"
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_PATH"

  /usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    UPLOAD_ZIP="$DIST_DIR/$APP_NAME-$VERSION-notarization-upload.zip"
    FINAL_ZIP="$DIST_DIR/$APP_NAME-$VERSION-macOS13-notarized.zip"

    echo "Submitting to Apple notarization profile: $NOTARY_PROFILE"
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$UPLOAD_ZIP"
    /usr/bin/xcrun notarytool submit "$UPLOAD_ZIP" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait

    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$FINAL_ZIP"

    echo "Created notarized release: $FINAL_ZIP"
  else
    FINAL_ZIP="$DIST_DIR/$APP_NAME-$VERSION-macOS13-signed-unnotarized.zip"
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
    echo "Created signed release without notarization: $FINAL_ZIP"
    echo "Set NOTARY_PROFILE to create the public-friendly notarized ZIP."
  fi
else
  echo "No DEVELOPER_ID set; building ad-hoc signed release..."
  /usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    build

  /usr/bin/codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP_PATH"
  FINAL_ZIP="$DIST_DIR/$APP_NAME-$VERSION-local-test.zip"
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
  echo "Created local-test ZIP: $FINAL_ZIP"
  echo "This build is not Developer ID notarized, so other Macs may require right-click > Open."
fi

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGING_DIR="$ROOT_DIR/.build/dmg-staging"
rm -rf "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
if [[ -f "$README_SRC" ]]; then
  cp "$README_SRC" "$DMG_STAGING_DIR/Install First — Read Me.txt"
fi
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
echo "Created DMG: $DMG_PATH"

# Regenerate the download-site manifest so its version always matches the
# packaged release. Existing release notes are preserved; only the version
# and download URL are derived from MARKETING_VERSION.
VERSION_JSON="$ROOT_DIR/download-site/version.json"
/usr/bin/python3 - "$VERSION" "$VERSION_JSON" <<'PY'
import json
import sys

version, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        manifest = json.load(f)
except (OSError, ValueError):
    manifest = {}

manifest["version"] = version
manifest["downloadURL"] = (
    "https://github.com/bhino50/finder-path/releases/download/"
    f"v{version}/FinderPath-{version}.dmg"
)
manifest.setdefault("notes", f"FinderPath {version}.")

with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
echo "Updated $VERSION_JSON to version $VERSION"

echo
echo "Signature:"
/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n '1,18p'

echo
echo "Architecture:"
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME"

echo
echo "Gatekeeper assessment:"
/usr/sbin/spctl -a -vv --type exec "$APP_PATH" || true
