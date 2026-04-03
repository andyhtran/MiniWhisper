# MiniWhisper

A minimal macOS menu bar app for voice-to-text with fast English transcription via [Parakeet](https://github.com/FluidInference/FluidAudio) and multilingual transcription via [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Press a hotkey, speak, and the transcription is automatically pasted into the active app.

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange)
![License MIT](https://img.shields.io/github/license/andyhtran/MiniWhisper)
![GitHub release](https://img.shields.io/github/v/release/andyhtran/MiniWhisper)

[Getting Started](#getting-started) · [Features](#features) · [Build](#build-commands)

<img src=".github/screenshot.png" alt="MiniWhisper screenshot" width="320">

## Getting Started

1. [**Download MiniWhisper**](https://github.com/andyhtran/MiniWhisper/releases/latest/download/MiniWhisper.dmg)
2. Open the DMG and drag the app to your Applications folder
3. Launch MiniWhisper from Applications (or search "MiniWhisper" in Spotlight)
4. Grant microphone and accessibility permissions when prompted
5. Look for the MiniWhisper icon in your menu bar (top-right of your screen)
6. Press **Option + `** to start recording, press it again to stop — the transcription is pasted into the frontmost app

Press **Escape** to cancel a recording. To change the hotkey, click the MiniWhisper icon in the menu bar and set a new shortcut (e.g. **Fn**).

<details>
<summary>Other install methods</summary>

### Homebrew

```bash
brew tap andyhtran/tap
brew install --cask miniwhisper
```

### Build from source

Requires macOS 14+ (Sonoma) and Swift 6+.

```bash
git clone https://github.com/andyhtran/MiniWhisper.git
cd MiniWhisper
just dev
```

</details>

## Features

- **Auto-paste** — transcriptions go straight into whatever app you're using
- **Customizable hotkey** — change the toggle shortcut from the menu bar panel
- **Text replacements** — auto-correct words or phrases after transcription
- **Recording history** — browse and copy recent transcriptions
- **Usage stats** — track recordings, speaking time, word count, and average WPM
- **Multiple models** — switch between fast English-only (Parakeet) and multilingual auto-detect (whisper.cpp)
- **On-device** — all processing happens locally on your Mac, nothing leaves your device

## Build commands

```bash
just dev          # Build, package, and launch
just build        # Debug build only
just release      # Release build + .app bundle
just debug-tool   # Build local debug transcription CLI
just clean        # Remove build artifacts
```

Run the local debug CLI on an existing audio file or recording directory:

```bash
just debug-transcribe ~/Code/debug-stt/whisper_cpp.wav --engine whisper --preset current-app
```

## Release

Signing, notarization, and publishing require [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI):

```bash
brew install asc
```

See `just --list` for the full set of release recipes (`sign-and-notarize`, `github-release`, `publish`, etc.).

## Configuration

Copy `.envrc.example` to `.envrc` and fill in your values. If using [direnv](https://direnv.net/), run `direnv allow`.

For local development, ad-hoc signing works out of the box — no Apple Developer account needed.

## License

[MIT](LICENSE)
