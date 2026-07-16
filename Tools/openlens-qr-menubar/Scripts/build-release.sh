#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/DerivedData/Release"
OUTPUT_DIR="$PROJECT_DIR/Release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/OpenLensRemote.app"
ZIP_PATH="$OUTPUT_DIR/OpenLensRemote.zip"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool Keychain profile.}"

"$SCRIPT_DIR/embed-cloudflared.sh"
cd "$PROJECT_DIR"
tuist generate --no-open

rm -rf "$DERIVED_DATA" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -workspace OpenLensRemote.xcworkspace \
  -scheme OpenLensRemote \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign --force --timestamp --options runtime \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_PATH/Contents/Resources/cloudflared-arm64"
codesign --force --timestamp --options runtime \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_PATH/Contents/Resources/cloudflared-amd64"
codesign --force --timestamp --options runtime \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"

printf 'Signed and notarized release: %s\n' "$ZIP_PATH"
