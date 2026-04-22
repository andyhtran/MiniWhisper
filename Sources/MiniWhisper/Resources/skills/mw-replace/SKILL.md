---
name: mw-replace
description: Add a text replacement rule to MiniWhisper (local voice-to-text macOS app) by appending a find/replace pair to its config and pinging the app to reload. Use when the user asks to replace one phrase with another, fix a recurring mis-transcription, or says things like "X → Y" or "replace X with Y".
---

# MiniWhisper: Add Replacement

## Capture the intent

Accept any of these as `<from>` → `<to>`:
- `clod -> Claude`
- `"clod code" -> "Claude Code"`
- `replace clod with Claude`

If unclear which side is which, ask.

## Do

1. Read `~/Documents/MiniWhisper/replacements.json`.
2. If a rule with the same `find` as `<from>` already exists, stop and ask the user how to proceed.
3. Otherwise, append `{ "find": <from>, "replace": <to>, "enabled": true }` to `rules`, preserving everything else. Write atomically (temp file + `mv`).
4. Run `notifyutil -p com.miniwhisper.config-changed`.
5. Confirm: `Added: '<from>' → '<to>'.`

For anything else, ask the user.
