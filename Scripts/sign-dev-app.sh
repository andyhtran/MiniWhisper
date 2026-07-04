#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

REQUIRE_DEVELOPER_ID=false
if [[ "${1:-}" == "--require-developer-id" ]]; then
    REQUIRE_DEVELOPER_ID=true
    shift
fi

APP=${1:?"Usage: $0 [--require-developer-id] <path-to-app>"}
ENTITLEMENTS="$ROOT/build/MiniWhisper.entitlements"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found: $APP" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi

find_developer_id_identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}'
}

choose_identity() {
    if [[ -n "${MINIWHISPER_DEV_CODESIGN_IDENTITY:-}" && "${MINIWHISPER_DEV_CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$MINIWHISPER_DEV_CODESIGN_IDENTITY"
        return
    fi

    if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local developer_id
    developer_id=$(find_developer_id_identity)
    if [[ -n "$developer_id" ]]; then
        printf '%s\n' "$developer_id"
        return
    fi

    if [[ -n "${DEV_CODESIGN_IDENTITY:-}" && "${DEV_CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$DEV_CODESIGN_IDENTITY"
        return
    fi

    printf '%s\n' "-"
}

IDENTITY=$(choose_identity)
if [[ "$REQUIRE_DEVELOPER_ID" == true && "$IDENTITY" == "-" ]]; then
    echo "No Developer ID Application identity found; Sparkle stays disabled without it." >&2
    exit 1
fi

echo "==> Signing ${APP} with: ${IDENTITY}"

sign_if_present() {
    local item="$1"
    [[ -e "$item" ]] || return 0
    codesign --force --sign "$IDENTITY" "$item"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for item in \
        "$SPARKLE/Versions/B/Sparkle" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app/Contents/MacOS/Updater" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B" \
        "$SPARKLE"; do
        sign_if_present "$item"
    done
fi

sign_if_present "$APP/Contents/Frameworks/whisper.framework"
sign_if_present "$APP/Contents/Resources/miniwhispercli"

codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

if [[ "$REQUIRE_DEVELOPER_ID" == true ]]; then
    signature_info=$(codesign -dvv "$APP" 2>&1)
    if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_info"; then
        echo "Expected a Developer ID Application signature, but ${APP} was signed differently." >&2
        exit 1
    fi
fi
