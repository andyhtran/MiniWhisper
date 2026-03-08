#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="MiniWhisper"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: $APP_BUNDLE not found. Run sign-and-notarize first."
    exit 1
fi

if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

echo "==> Creating DMG..."
rm -f "$DMG_NAME"

create-dmg \
    --volname "$APP_NAME" \
    --window-size 660 400 \
    --icon-size 160 \
    --icon "$APP_NAME.app" 180 170 \
    --app-drop-link 480 170 \
    --no-internet-enable \
    "$DMG_NAME" \
    "$APP_BUNDLE"

echo "Done: $DMG_NAME ($(shasum -a 256 "$DMG_NAME" | cut -d' ' -f1))"
