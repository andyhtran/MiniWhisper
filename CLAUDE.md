# MiniWhisper

**CLI-only** — no Xcode. All builds use `swift build` via SPM. Use `just` as the task runner.

- macOS 14.0+, Swift 6.0+

```bash
just dev          # Kill existing, build, package, launch
just build        # Debug build
just package      # Release build + create .app bundle
just clean        # Remove build artifacts
```

## Releasing

After a PR is merged:

1. Bump `MARKETING_VERSION` and `BUILD_NUMBER` in `version.env`
2. Commit, push to main
3. Run `just publish` — signs, notarizes, creates GitHub release with tag + assets, and updates the Homebrew tap
