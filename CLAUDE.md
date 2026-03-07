# MiniWhisper

**CLI-only** — no Xcode. All builds use `swift build` via SPM. Use `just` as the task runner.

- macOS 14.0+, Swift 6.0+

```bash
just dev          # Kill existing, build, package, launch
just build        # Debug build
just package      # Release build + create .app bundle
just clean        # Remove build artifacts
```
