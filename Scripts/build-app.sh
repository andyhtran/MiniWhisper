#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="MiniWhisper"
BUILD_CONFIG="${1:-release}"
BUILD_DIR=".build/${BUILD_CONFIG}"
APP_BUNDLE="build/${APP_NAME}.app"
BUNDLE_ID_DEBUG="com.miniwhisper.dev"
BUNDLE_ID_RELEASE="com.miniwhisper.app"

if [[ "$BUILD_CONFIG" == "debug" ]]; then
    BUNDLE_ID="$BUNDLE_ID_DEBUG"
    DISPLAY_NAME="MiniWhisper Dev"
else
    BUNDLE_ID="$BUNDLE_ID_RELEASE"
    DISPLAY_NAME="MiniWhisper"
fi

echo "Building $APP_NAME ($BUILD_CONFIG)..."

swift build -c "$BUILD_CONFIG" --product "$APP_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Embed whisper.framework with proper macOS versioned structure
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
if [ -d "$BUILD_DIR/whisper.framework" ]; then
    mkdir -p "$FRAMEWORKS_DIR/whisper.framework/Versions/A"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Headers" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Modules" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Resources" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp "$BUILD_DIR/whisper.framework/Versions/A/whisper" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    ln -sf A "$FRAMEWORKS_DIR/whisper.framework/Versions/Current"
    ln -sf Versions/Current/Headers "$FRAMEWORKS_DIR/whisper.framework/Headers"
    ln -sf Versions/Current/Modules "$FRAMEWORKS_DIR/whisper.framework/Modules"
    ln -sf Versions/Current/Resources "$FRAMEWORKS_DIR/whisper.framework/Resources"
    ln -sf Versions/Current/whisper "$FRAMEWORKS_DIR/whisper.framework/whisper"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Andy Tran. All rights reserved.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MiniWhisper needs microphone access to record and transcribe speech.</string>
</dict>
</plist>
PLIST

cp "Sources/MiniWhisper/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy entitlements (used by signing in justfile, not embedded in bundle)
cp "Sources/MiniWhisper/Resources/MiniWhisper.entitlements" "build/"

echo "Bundle created: $APP_BUNDLE"
