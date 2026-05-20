---
name: mw-replace
description: "Add a text replacement rule to MiniWhisper (local voice-to-text macOS app) by appending a find/replace pair to its config and pinging the app to reload. Use when the user asks to replace one phrase with another, fix a recurring mis-transcription, or says things like \"X → Y\" or \"replace X with Y\"."
---

# MiniWhisper: Add Replacement

## Capture the intent

Accept any of these as `<from>` → `<to>`:
- `clod -> Claude`
- `"clod code" -> "Claude Code"`
- `replace clod with Claude`

If unclear which side is which, ask.

## Config format (v2 grouped schema)

```json
{
  "schemaVersion": 2,
  "enabled": true,
  "groups": [
    {
      "id": "UUID",
      "enabled": true,
      "replacement": "Claude",
      "preserveCase": false,
      "variants": [
        { "id": "UUID", "enabled": true, "find": "clawd" },
        { "id": "UUID", "enabled": true, "find": "clawed" }
      ]
    }
  ]
}
```

- `replacement` is the correct/target text (what it becomes).
- `variants` are the misheard transcription strings (what to match).
- Each group and variant has a UUID `id`.

## Do

1. Read `~/Documents/MiniWhisper/replacements.json`.
2. Search `groups` for an existing group whose `replacement` matches `<to>` (case-insensitive).
   - **If found:** check if a variant with `find` matching `<from>` (case-insensitive) already exists in that group. If yes, stop and tell the user. If no, append `{ "id": "<new-uuid>", "enabled": true, "find": "<from>" }` to that group's `variants` array.
   - **If not found:** append a new group to `groups`:
     ```json
     {
       "id": "<new-uuid>",
       "enabled": true,
       "replacement": "<to>",
       "preserveCase": false,
       "variants": [
         { "id": "<new-uuid>", "enabled": true, "find": "<from>" }
       ]
     }
     ```
3. Write atomically (temp file + `mv`). Preserve `prettyPrinted` + `sortedKeys` formatting.
4. Run `notifyutil -p com.miniwhisper.config-changed`.
5. Confirm: `Added: '<from>' → '<to>'.`

Generate UUIDs with `uuidgen`.

For anything else, ask the user.
