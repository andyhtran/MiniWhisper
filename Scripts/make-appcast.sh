#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

ZIP=${1:?"Usage: $0 <MiniWhisper-<ver>.zip>"}
FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/andyhtran/MiniWhisper/main/appcast.xml}"
SPARKLE_CHANNEL="${SPARKLE_CHANNEL:-}"

if [[ ! -f "$ZIP" ]]; then
    echo "Zip not found: $ZIP" >&2
    exit 1
fi

if ! command -v generate_appcast &>/dev/null; then
    echo "generate_appcast not found. Install: brew install andyhtran/tap/sparkle-tools" >&2
    exit 1
fi

ZIP_DIR=$(cd "$(dirname "$ZIP")" && pwd)
ZIP_NAME=$(basename "$ZIP")

DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/andyhtran/MiniWhisper/releases/download/v${MARKETING_VERSION}/}"

WORK_DIR=$(mktemp -d /tmp/appcast-gen.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [[ -f "$ROOT/appcast.xml" ]]; then
    cp "$ROOT/appcast.xml" "$WORK_DIR/appcast.xml"
fi
cp "$ZIP" "$WORK_DIR/$ZIP_NAME"

# Sparkle pairs release notes to an archive purely by filename, so the notes have
# to land beside the zip under the same basename. Missing notes are not fatal —
# the item just ships with an empty description, which is what every release
# before 1.10.0 did — but it is silent in the update dialog, so say so here.
NOTES_NAME="${ZIP_NAME%.zip}.html"
if [[ -f "$ROOT/ReleaseNotes/$NOTES_NAME" ]]; then
    cp "$ROOT/ReleaseNotes/$NOTES_NAME" "$WORK_DIR/$NOTES_NAME"
    echo "Embedding release notes: ReleaseNotes/$NOTES_NAME"
else
    echo "WARNING: no ReleaseNotes/$NOTES_NAME — update dialog will show no description." >&2
fi

CHANNEL_ARGS=()
if [[ -n "$SPARKLE_CHANNEL" ]]; then
    CHANNEL_ARGS=(--channel "$SPARKLE_CHANNEL")
fi

generate_appcast \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --embed-release-notes \
    --link "$FEED_URL" \
    "${CHANNEL_ARGS[@]}" \
    "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$ROOT/appcast.xml"

echo "Appcast updated: appcast.xml"
echo "Upload $ZIP_NAME to GitHub release, then commit appcast.xml."
