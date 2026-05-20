#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/FinderPath.xcodeproj"
SCHEME="FinderPath"
CONFIGURATION="Release"
APP_NAME="FinderPath"
VERSION="1.2"
DERIVED_DATA_PATH="$ROOT_DIR/.build/PackageDerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"

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
  echo "No DEVELOPER_ID set; building local-test ZIP only."
  /usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=NO \
    build

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
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
echo "Created DMG: $DMG_PATH"

echo
echo "Signature:"
/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n '1,18p'

echo
echo "Architecture:"
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME"

echo
echo "Gatekeeper assessment:"
/usr/sbin/spctl -a -vv --type exec "$APP_PATH" || true
