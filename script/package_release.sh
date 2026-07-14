#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/FinderPath.xcodeproj"
PBXPROJ="$PROJECT_PATH/project.pbxproj"
SCHEME="FinderPath"
CONFIGURATION="Release"
APP_NAME="FinderPath"

# All project configurations must agree so the artifact name cannot drift from
# the version embedded in the app bundle.
VERSION_VALUES="$(
  /usr/bin/awk -F ' = ' '
    /^[[:space:]]*MARKETING_VERSION = / {
      value = $2
      sub(/;.*/, "", value)
      gsub(/[[:space:]\"]/, "", value)
      print value
    }
  ' "$PBXPROJ" | /usr/bin/sort -u
)"
if [[ -z "$VERSION_VALUES" || "$VERSION_VALUES" == *$'\n'* ]]; then
  echo "Expected one consistent MARKETING_VERSION in $PBXPROJ; found:" >&2
  echo "${VERSION_VALUES:-<none>}" >&2
  exit 1
fi
VERSION="$VERSION_VALUES"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "MARKETING_VERSION is not safe for an artifact filename: $VERSION" >&2
  exit 1
fi

DERIVED_DATA_PATH="$ROOT_DIR/.build/PackageDerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
README_SRC="$ROOT_DIR/script/dmg-install-readme.txt"
ENTITLEMENTS="$ROOT_DIR/FinderPath.entitlements"
DMG_STAGING_DIR="$ROOT_DIR/.build/dmg-staging"
VERSION_JSON="$ROOT_DIR/download-site/version.json"
DOWNLOAD_INDEX="$ROOT_DIR/download-site/index.html"

if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID:-}" ]]; then
  echo "NOTARY_PROFILE requires DEVELOPER_ID; refusing to create an ambiguous artifact." >&2
  exit 2
fi

PUBLIC_RELEASE=false
PUBLIC_PROMOTION_COMPLETE=false
NOTARY_CANDIDATE=""
NOTARY_APP_UPLOAD=""
APP_ARCHIVE_CANDIDATE=""
if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  RELEASE_KIND="public notarized"
  PUBLIC_RELEASE=true
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  NOTARY_CANDIDATE="$DIST_DIR/.$APP_NAME-$VERSION-NOTARIZATION-CANDIDATE-NOT-FOR-PUBLIC-RELEASE.dmg"
  DMG_WORK_PATH="$NOTARY_CANDIDATE"
  APP_ARCHIVE_PATH="$DIST_DIR/$APP_NAME-$VERSION-macOS13-notarized.zip"
  APP_ARCHIVE_CANDIDATE="$DIST_DIR/.$APP_NAME-$VERSION-NOTARIZED-ARCHIVE-CANDIDATE-NOT-FOR-PUBLIC-RELEASE.zip"
  APP_ARCHIVE_WORK_PATH="$APP_ARCHIVE_CANDIDATE"
  NOTARY_APP_UPLOAD="$DIST_DIR/.$APP_NAME-$VERSION-APP-NOTARIZATION-UPLOAD-NOT-FOR-PUBLIC-RELEASE.zip"
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
  RELEASE_KIND="Developer ID signed, unnotarized"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-SIGNED-UNNOTARIZED-NOT-FOR-PUBLIC-RELEASE.dmg"
  DMG_WORK_PATH="$DMG_PATH"
  APP_ARCHIVE_PATH="$DIST_DIR/$APP_NAME-$VERSION-SIGNED-UNNOTARIZED-NOT-FOR-PUBLIC-RELEASE.zip"
  APP_ARCHIVE_WORK_PATH="$APP_ARCHIVE_PATH"
else
  RELEASE_KIND="ad-hoc local-only"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-ADHOC-LOCAL-ONLY-NOT-FOR-PUBLIC-RELEASE.dmg"
  DMG_WORK_PATH="$DMG_PATH"
  APP_ARCHIVE_PATH="$DIST_DIR/$APP_NAME-$VERSION-ADHOC-LOCAL-ONLY-NOT-FOR-PUBLIC-RELEASE.zip"
  APP_ARCHIVE_WORK_PATH="$APP_ARCHIVE_PATH"
fi

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

cleanup() {
  rm -rf "$DMG_STAGING_DIR"
  if [[ "$PUBLIC_RELEASE" == true && "$PUBLIC_PROMOTION_COMPLETE" != true ]]; then
    rm -f "$DMG_PATH" "$APP_ARCHIVE_PATH"
  fi
  if [[ -n "$NOTARY_CANDIDATE" ]]; then
    rm -f "$NOTARY_CANDIDATE"
  fi
  if [[ -n "$NOTARY_APP_UPLOAD" ]]; then
    rm -f "$NOTARY_APP_UPLOAD"
  fi
  if [[ -n "$APP_ARCHIVE_CANDIDATE" ]]; then
    rm -f "$APP_ARCHIVE_CANDIDATE"
  fi
}
trap cleanup EXIT

update_public_manifest() {
  /usr/bin/python3 - "$VERSION" "$VERSION_JSON" "$DOWNLOAD_INDEX" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile

version, manifest_path, index_path = sys.argv[1:4]
with open(manifest_path, encoding="utf-8") as source:
    original_manifest = source.read()
manifest = json.loads(original_manifest)
if not isinstance(manifest, dict):
    raise ValueError(f"{manifest_path} must contain a JSON object")

manifest["version"] = version
manifest["downloadURL"] = (
    "https://github.com/bhino50/finder-path/releases/download/"
    f"v{version}/FinderPath-{version}.dmg"
)
manifest["notes"] = os.environ.get("RELEASE_NOTES", f"FinderPath {version}.")

with open(index_path, encoding="utf-8") as source:
    original_index = source.read()
index, replacements = re.subn(
    r'(class="release-note">Version )[0-9A-Za-z._-]+',
    rf'\g<1>{version}',
    index,
    count=1,
)
if replacements != 1:
    raise ValueError(f"Could not update the release version label in {index_path}")

def stage_file(path, prefix, write_content):
    directory = os.path.dirname(path) or "."
    mode = stat.S_IMODE(os.stat(path).st_mode)
    temporary_path = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=prefix, delete=False
        ) as destination:
            temporary_path = destination.name
            write_content(destination)
        os.chmod(temporary_path, mode)
        return temporary_path
    except Exception:
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
        raise

def write_manifest(destination):
    json.dump(manifest, destination, indent=2)
    destination.write("\n")

manifest_staged = stage_file(
    manifest_path,
    ".version.",
    write_manifest,
)
index_staged = ""
manifest_rollback = ""
manifest_replaced = False
try:
    index_staged = stage_file(index_path, ".index.", lambda destination: destination.write(index))
    manifest_rollback = stage_file(
        manifest_path,
        ".rollback.",
        lambda destination: destination.write(original_manifest),
    )
    os.replace(manifest_staged, manifest_path)
    manifest_staged = ""
    manifest_replaced = True
    os.replace(index_staged, index_path)
    index_staged = ""
except Exception:
    # If the second commit fails, restore the exact original manifest before
    # reporting failure so the updater can never point at artifacts cleanup
    # is about to remove.
    if manifest_replaced:
        os.replace(manifest_rollback, manifest_path)
        manifest_rollback = ""
    raise
finally:
    for temporary_path in (manifest_staged, index_staged, manifest_rollback):
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
PY
}

rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "Packaging $APP_NAME version $VERSION (from MARKETING_VERSION)"
echo "Release mode: $RELEASE_KIND"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "Xcode developer directory: $DEVELOPER_DIR"
fi

echo "Building unsigned Release app..."
/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing app with Developer ID: $DEVELOPER_ID"
  /usr/bin/codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_PATH"
else
  echo "Applying an ad-hoc app signature for local use only..."
  /usr/bin/codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - \
    "$APP_PATH"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ -n "${DEVELOPER_ID:-}" ]] && ! /usr/bin/codesign -dvv "$APP_PATH" 2>&1 | /usr/bin/grep '^Timestamp=' >/dev/null; then
  echo "Developer ID app signature is missing a trusted timestamp." >&2
  exit 1
fi

if [[ "$PUBLIC_RELEASE" == true ]]; then
  echo "Submitting a temporary app ZIP to Apple notarization profile: $NOTARY_PROFILE"
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$NOTARY_APP_UPLOAD"
  /usr/bin/xcrun notarytool submit "$NOTARY_APP_UPLOAD" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  rm -f "$NOTARY_APP_UPLOAD"

  echo "Stapling, validating, and requiring Gatekeeper acceptance for the app..."
  /usr/bin/xcrun stapler staple "$APP_PATH"
  /usr/bin/xcrun stapler validate "$APP_PATH"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$APP_ARCHIVE_WORK_PATH"
else
  /usr/bin/ditto -c -k --norsrc --keepParent "$APP_PATH" "$APP_ARCHIVE_WORK_PATH"
fi

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
if [[ -f "$README_SRC" ]]; then
  /usr/bin/sed "s/<version>/$VERSION/g" \
    "$README_SRC" > "$DMG_STAGING_DIR/Install First — Read Me.txt"
fi
if [[ "$PUBLIC_RELEASE" != true ]]; then
  /usr/bin/printf '%s\n' \
    'NOT FOR PUBLIC RELEASE' \
    '' \
    "This $RELEASE_KIND build has not passed Apple notarization." \
    'Use it only for local testing. Do not upload it or point an update manifest at it.' \
    > "$DMG_STAGING_DIR/NOT FOR PUBLIC RELEASE.txt"
fi

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_WORK_PATH" >/dev/null
echo "Created DMG candidate: $DMG_WORK_PATH"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing the DMG with Developer ID..."
  /usr/bin/codesign --force --sign "$DEVELOPER_ID" "$DMG_WORK_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_WORK_PATH"
  if ! /usr/bin/codesign -dvv "$DMG_WORK_PATH" 2>&1 | /usr/bin/grep '^Timestamp=' >/dev/null; then
    echo "Developer ID DMG signature is missing a trusted timestamp." >&2
    exit 1
  fi
fi

if [[ "$PUBLIC_RELEASE" == true ]]; then
  echo "Submitting the DMG itself to Apple notarization profile: $NOTARY_PROFILE"
  /usr/bin/xcrun notarytool submit "$DMG_WORK_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling and validating the DMG notarization ticket..."
  /usr/bin/xcrun stapler staple "$DMG_WORK_PATH"
  /usr/bin/xcrun stapler validate "$DMG_WORK_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_WORK_PATH"

  echo "Requiring Gatekeeper acceptance for the DMG..."
  /usr/sbin/spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$DMG_WORK_PATH"

  # Promote both independently validated artifacts to clean public filenames
  # only after every app and DMG trust check passes.
  mv "$DMG_WORK_PATH" "$DMG_PATH"
  mv "$APP_ARCHIVE_WORK_PATH" "$APP_ARCHIVE_PATH"
  update_public_manifest
  PUBLIC_PROMOTION_COMPLETE=true
  echo "Created notarized public release: $DMG_PATH"
  echo "Updated $VERSION_JSON and $DOWNLOAD_INDEX to version $VERSION"
else
  echo "Created non-public DMG: $DMG_PATH"
  echo "Created non-public app archive: $APP_ARCHIVE_PATH"
  echo "Public manifest was not modified."
  echo "Gatekeeper acceptance is intentionally not claimed for this $RELEASE_KIND build."
fi

echo
echo "App signature:"
/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/sed -n '1,18p'

echo
echo "Architecture:"
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME"
