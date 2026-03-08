app_name := "MiniWhisper"
bundle_id := "com.miniwhisper.dev"
signing_id := env("CODESIGN_IDENTITY", "-")
team_id := env("CODESIGN_TEAM_ID", "")
install_path := "/Applications/MiniWhisper Dev.app"

default:
    @just --list --unsorted

# Kill existing, build, sign, install to /Applications, and launch
[group('dev')]
dev: kill build package
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{install_path}}"
    cp -R build/{{app_name}}.app "{{install_path}}"
    if [[ -n "{{team_id}}" ]]; then
    codesign --force --sign "{{signing_id}}" \
        --entitlements build/MiniWhisper.entitlements \
        -r='designated => anchor apple generic and identifier "{{bundle_id}}" and certificate leaf[subject.OU] = "{{team_id}}"' \
        "{{install_path}}"
    else
    codesign --force --sign "{{signing_id}}" \
        --entitlements build/MiniWhisper.entitlements \
        "{{install_path}}"
    fi
    rm -rf build/{{app_name}}.app
    open "{{install_path}}"

# Debug build
[group('build')]
build:
    swift build

# Create .app bundle (debug)
[group('build')]
package:
    bash Scripts/build-app.sh debug

# Release build + package
[group('build')]
release:
    bash Scripts/build-app.sh release

# Remove build artifacts
[group('build')]
clean:
    rm -rf .build build *.zip

# Sign, notarize, and package for distribution
[group('release')]
sign-and-notarize:
    bash Scripts/sign-and-notarize.sh

# Create DMG installer from signed app
[group('release')]
create-dmg: sign-and-notarize
    bash Scripts/create-dmg.sh

# Create GitHub release and upload zip + dmg
[group('release')]
github-release: sign-and-notarize create-dmg
    #!/usr/bin/env bash
    source version.env
    TAG="v${MARKETING_VERSION}"
    ZIP="MiniWhisper-${MARKETING_VERSION}.zip"
    DMG="MiniWhisper.dmg"
    git tag -f "$TAG"
    git push -f origin "$TAG"
    gh release create "$TAG" "$ZIP" "$DMG" \
        --title "MiniWhisper ${MARKETING_VERSION}" \
        --generate-notes

# Update homebrew tap with new version
[group('release')]
update-tap:
    bash Scripts/update-tap.sh

# Full release: sign, notarize, GitHub release, update tap
[group('release')]
publish: github-release update-tap
    @echo "Release complete!"

# Kill running instance
[group('dev')]
kill:
    -pkill -f "{{app_name}}" 2>/dev/null || true
    -pkill -f "MiniWhisper Dev" 2>/dev/null || true

# Reset TCC permissions (use when permissions get stuck)
[group('dev')]
reset-tcc:
    sudo tccutil reset ListenEvent {{bundle_id}}
    sudo tccutil reset Accessibility {{bundle_id}}
    sudo tccutil reset Microphone {{bundle_id}}
    @echo "TCC permissions reset. Re-run 'just run' and grant permissions when prompted."

# Reset app UserDefaults
[group('dev')]
reset-settings:
    -killall "{{app_name}}" 2>/dev/null || true
    -killall "MiniWhisper Dev" 2>/dev/null || true
    defaults delete {{bundle_id}} 2>/dev/null || true
    @echo "Settings reset. Restart the app to use defaults."
