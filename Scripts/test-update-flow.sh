#!/usr/bin/env bash
#
# Local end-to-end test of the Sparkle update flow with the real updater:
#
#   1. Builds the current version as "MiniWhisper Dev.app", Developer ID
#      signed (required for UpdaterFactory to enable Sparkle), with its feed
#      pointed at a localhost appcast.
#   2. Builds a version-bumped copy, signs it, zips it, and generates a
#      signed appcast for it (requires the Sparkle EdDSA private key in the
#      login Keychain, same as a real release).
#   3. Serves zip + appcast on localhost and launches the old version.
#
# From there: open the menu popover, Check Now (footer → Settings, or the
# Settings window), and watch available → downloading → preparing →
# installing → relaunch as the bumped version. Ctrl-C stops the server.
#
# Nothing is committed or uploaded; version.env is restored on exit.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PORT="${PORT:-8123}"
FEED="http://localhost:${PORT}/appcast.xml"
INSTALL_PATH="/Applications/MiniWhisper Dev.app"
DEV_EXEC="${INSTALL_PATH}/Contents/MacOS/MiniWhisper"

if ! command -v generate_appcast &>/dev/null; then
    echo "generate_appcast not found. Install: brew install andyhtran/tap/sparkle-tools" >&2
    exit 1
fi

source version.env
SERVE_DIR=$(mktemp -d /tmp/mw-update-test.XXXXXX)
VERSION_BACKUP=$(mktemp /tmp/mw-version-env.XXXXXX)
cp version.env "$VERSION_BACKUP"

SERVER_PID=""
cleanup() {
    cp "$VERSION_BACKUP" version.env
    rm -f "$VERSION_BACKUP"
    rm -rf "$SERVE_DIR"
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

quit_dev_app() {
    osascript -e 'tell application id "com.miniwhisper.dev" to quit' \
        >/dev/null 2>&1 || true
    sleep 1
    while read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(pgrep -f "$DEV_EXEC" 2>/dev/null || true)
}

echo "==> Building current version (${MARKETING_VERSION}, build ${BUILD_NUMBER})..."
SPARKLE_FEED_URL_OVERRIDE="$FEED" bash Scripts/build-app.sh debug
bash Scripts/sign-dev-app.sh --require-developer-id "build/MiniWhisper.app"

echo "==> Installing to ${INSTALL_PATH}..."
quit_dev_app
rm -rf "$INSTALL_PATH"
cp -R "build/MiniWhisper.app" "$INSTALL_PATH"

NEW_MARKETING="${MARKETING_VERSION%.*}.$((${MARKETING_VERSION##*.} + 1))"
NEW_BUILD=$((BUILD_NUMBER + 1))
echo "==> Building update (${NEW_MARKETING}, build ${NEW_BUILD})..."
sed -i '' \
    -e "s/^MARKETING_VERSION=.*/MARKETING_VERSION=${NEW_MARKETING}/" \
    -e "s/^BUILD_NUMBER=.*/BUILD_NUMBER=${NEW_BUILD}/" \
    version.env
SPARKLE_FEED_URL_OVERRIDE="$FEED" bash Scripts/build-app.sh debug
cp "$VERSION_BACKUP" version.env
bash Scripts/sign-dev-app.sh --require-developer-id "build/MiniWhisper.app"

echo "==> Generating signed appcast..."
/usr/bin/ditto -c -k --keepParent "build/MiniWhisper.app" \
    "$SERVE_DIR/MiniWhisper-${NEW_MARKETING}.zip"
rm -rf "build/MiniWhisper.app"
generate_appcast \
    --download-url-prefix "http://localhost:${PORT}/" \
    --link "$FEED" \
    "$SERVE_DIR"

echo "==> Serving appcast on port ${PORT}..."
python3 -m http.server "$PORT" --directory "$SERVE_DIR" --bind 127.0.0.1 \
    >/dev/null 2>&1 &
SERVER_PID=$!

# The debug-only UpdateSimulator shadows the real updater when its defaults
# key is set; a leftover key from a simulator session would silently turn
# this whole test into a simulation.
defaults delete com.miniwhisper.dev "UpdateSimulatorScenario" 2>/dev/null || true

open "$INSTALL_PATH"

cat <<INSTRUCTIONS

Running: MiniWhisper Dev ${MARKETING_VERSION} (build ${BUILD_NUMBER})
Update:  ${NEW_MARKETING} (build ${NEW_BUILD}) served at ${FEED}

Try it:
  - Menu popover → footer Settings → "Check for Updates", or the Settings
    window → "Check Now".
  - Expect the banner: Update Available ${NEW_MARKETING} → Install →
    Downloading → Preparing → Installing → app relaunches as ${NEW_MARKETING}.
  - Scheduled background checks are enabled too; if you wait instead of
    clicking, discovery arrives as a banner + notification.

Verify afterwards: popover footer or Settings → About shows ${NEW_MARKETING}.

Ctrl-C stops the server (version.env already restored).
INSTRUCTIONS

wait "$SERVER_PID"
