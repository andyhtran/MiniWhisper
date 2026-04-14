#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="MiniWhisper"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
TAP_DIR="${TAP_DIR:?Set TAP_DIR to your local homebrew-tap checkout}"
CASK_FILE="$TAP_DIR/Casks/miniwhisper.rb"

if [[ ! -f "$ZIP_NAME" ]]; then
    echo "ERROR: $ZIP_NAME not found. Run 'just sign-and-notarize' first." >&2
    exit 1
fi

SHA=$(shasum -a 256 "$ZIP_NAME" | cut -d' ' -f1)

echo "==> Updating cask: version=$MARKETING_VERSION sha256=$SHA"

echo "==> Syncing homebrew-tap..."
cd "$TAP_DIR"
# Pull before writing — other projects push to this repo from CI,
# so the local clone can fall behind. Pulling after writing would
# fail because rebase refuses to run with unstaged changes.
git pull --rebase

echo "==> Updating cask file..."
cd "$ROOT"
mkdir -p "$TAP_DIR/Casks"
cat > "$CASK_FILE" << RUBY
cask "miniwhisper" do
  version "${MARKETING_VERSION}"
  sha256 "${SHA}"

  url "https://github.com/andyhtran/MiniWhisper/releases/download/v#{version}/MiniWhisper-#{version}.zip"
  name "MiniWhisper"
  desc "Voice-to-text transcription from the menu bar"
  homepage "https://github.com/andyhtran/MiniWhisper"

  depends_on macos: ">= :sonoma"

  app "MiniWhisper.app"

  zap trash: [
    "~/Library/Preferences/com.miniwhisper.app.plist",
    "~/Library/Application Support/MiniWhisper",
  ]
end
RUBY

echo "==> Committing to homebrew-tap..."
cd "$TAP_DIR"
git add "Casks/miniwhisper.rb"
git commit -m "miniwhisper ${MARKETING_VERSION}"
git push

echo "Done: cask updated to ${MARKETING_VERSION}"
