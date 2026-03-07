# MiniWhisper

A minimal macOS menu bar app for voice-to-text using the [Parakeet](https://github.com/FluidInference/FluidAudio) model. Press a hotkey, speak, and the transcription is automatically pasted into the active app.

## Install

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

## Usage

1. Launch MiniWhisper — it lives in your menu bar
2. Grant microphone and accessibility permissions when prompted
3. Press **Option + `** to start recording (customizable in the menu bar panel)
4. Press the hotkey again to stop — the transcription is pasted into the frontmost app
5. Press **Escape** to cancel a recording

Your clipboard is preserved: MiniWhisper temporarily uses it to paste, then restores the previous contents.

## Features

- **Auto-paste** — transcriptions go straight into whatever app you're using
- **Customizable hotkey** — change the toggle shortcut from the menu bar panel
- **Text replacements** — auto-correct words or phrases after transcription
- **Recording history** — browse and copy recent transcriptions
- **Usage stats** — track recordings, speaking time, word count, and average WPM
- **On-device** — all processing happens locally via the Parakeet model, nothing leaves your Mac

## Build commands

```bash
just dev          # Build, package, and launch
just build        # Debug build only
just release      # Release build + .app bundle
just clean        # Remove build artifacts
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
