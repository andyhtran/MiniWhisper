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

# create-dmg uses AppleScript to style the Finder window, which is
# flaky on newer macOS — Finder sometimes isn't ready, causing
# error -10006. Retry up to 3 times before giving up.
MAX_ATTEMPTS=3
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if create-dmg \
        --volname "$APP_NAME" \
        --window-size 660 400 \
        --icon-size 160 \
        --icon "$APP_NAME.app" 180 170 \
        --app-drop-link 480 170 \
        --no-internet-enable \
        "$DMG_NAME" \
        "$APP_BUNDLE"; then
        break
    fi

    if [[ $attempt -eq $MAX_ATTEMPTS ]]; then
        echo "ERROR: create-dmg failed after $MAX_ATTEMPTS attempts" >&2
        exit 1
    fi

    echo "==> Attempt $attempt failed, retrying..."
    rm -f "$DMG_NAME"
    sleep 2
done

echo "Done: $DMG_NAME ($(shasum -a 256 "$DMG_NAME" | cut -d' ' -f1))"
