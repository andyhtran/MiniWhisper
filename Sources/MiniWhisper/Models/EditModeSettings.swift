import Foundation

/// User-selectable model for the edit-mode shortcut. `claude-*` and
/// `gpt-*` route through `EditModeProvider` (the OAuth path, reading
/// tokens from the user's Claude Code keychain entry /
/// `~/.codex/auth.json`); `.custom` routes through `CustomEditProvider`
/// to a user-supplied OpenAI-compatible chat-completions endpoint.
enum EditModeModel: String, Codable, CaseIterable, Sendable {
    case gpt5Mini = "gpt-5.4-mini"
    case claudeHaiku45 = "claude-haiku-4-5"
    case custom = "custom"

    var displayName: String { rawValue }

    var backend: EditModeBackend {
        switch self {
        case .claudeHaiku45: return .claudeCli
        case .gpt5Mini: return .codexCli
        case .custom: return .customApi
        }
    }

    /// Provider ID `EditModeProvider` dispatches on. Unused for
    /// `.custom`, which routes through `CustomEditProvider` instead.
    var oauthProvider: String {
        switch self {
        case .claudeHaiku45: return "anthropic"
        case .gpt5Mini: return "openai-codex"
        case .custom: return ""
        }
    }

    /// Reasoning-effort arg for the OAuth call. `nil` for Claude (no
    /// reasoning concept on these models in the API surface) and
    /// `.custom` (which never routes through the OAuth path); `"none"`
    /// for gpt models — edit/cleanup passes are short rewrites, so
    /// minimum reasoning keeps latency tight.
    var reasoningEffort: String? {
        switch self {
        case .claudeHaiku45: return nil
        case .gpt5Mini: return "none"
        case .custom: return nil
        }
    }
}

/// Which backend dispatches the edit. The OAuth-backed cases (`.claude`
/// and `.codex`) post directly to the inference endpoints using the
/// tokens managed by the user's installed Claude Code / Codex CLIs.
/// `.customApi` posts to a user-supplied OpenAI-compatible
/// chat-completions endpoint with a bearer token.
enum EditModeBackend: String, Codable, Sendable {
    case claudeCli = "claude"
    case codexCli = "codex"
    case customApi = "custom-api"

    var displayName: String {
        switch self {
        case .claudeCli: return "Claude"
        case .codexCli: return "Codex"
        case .customApi: return "Custom"
        }
    }
}

/// Top-level mode for AI editing. The two underlying features are:
/// `voiceEdit` (the ⌥E shortcut → record an instruction → rewrite the
/// selected text) and `autoCleanup` (every Fn recording gets an LLM
/// polish pass after transcription before insertion). They share the
/// Edit Model + provider, so one picker drives both knobs.
///
/// `both` is a convenience union; if/when a third feature appears, this
/// should migrate to independent toggles to avoid combinatorial bloat.
enum EditModeBehavior: String, Codable, CaseIterable, Sendable {
    case off
    case both
    case autoCleanup
    case voiceEdit

    var voiceEditEnabled: Bool {
        switch self {
        case .voiceEdit, .both: return true
        case .off, .autoCleanup: return false
        }
    }

    var autoCleanupEnabled: Bool {
        switch self {
        case .autoCleanup, .both: return true
        case .off, .voiceEdit: return false
        }
    }

    var isOff: Bool { self == .off }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .both: return "Both"
        case .autoCleanup: return "Cleanup"
        case .voiceEdit: return "Voice Edit"
        }
    }
}

/// Settings for AI editing (voice-edit + auto-cleanup).
enum EditModeSettings {
    private static let behaviorKey = "EditModeBehavior"
    private static let modelKey = "EditModeModel"

    static var behavior: EditModeBehavior {
        get {
            guard let raw = UserDefaults.standard.string(forKey: behaviorKey),
                  let behavior = EditModeBehavior(rawValue: raw)
            else {
                return .off
            }
            return behavior
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: behaviorKey) }
    }

    static var model: EditModeModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modelKey),
                  let model = EditModeModel(rawValue: raw)
            else {
                return .claudeHaiku45
            }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
    }
}
