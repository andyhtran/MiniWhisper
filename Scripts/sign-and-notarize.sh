#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="MiniWhisper"
APP_BUNDLE="build/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
SIGNING_ID="${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"

echo "==> Building release..."
bash "$ROOT/Scripts/build-app.sh" release

echo "==> Signing with: $SIGNING_ID"
codesign --force --timestamp --options runtime \
    --sign "$SIGNING_ID" \
    --entitlements "build/MiniWhisper.entitlements" \
    "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Creating zip for notarization..."
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

echo "==> Submitting for notarization..."
asc notarization submit --file "/tmp/${APP_NAME}Notarize.zip" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

echo "==> Verifying notarization..."
spctl -a -t exec -vv "$APP_BUNDLE"

echo "==> Creating release zip..."
rm -f "$ZIP_NAME" "/tmp/${APP_NAME}Notarize.zip"
xattr -cr "$APP_BUNDLE"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

echo "Done: $ZIP_NAME ($(shasum -a 256 "$ZIP_NAME" | cut -d' ' -f1))"
