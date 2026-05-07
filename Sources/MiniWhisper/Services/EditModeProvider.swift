import Foundation

/// Edit-mode backend that posts to the Anthropic / Codex inference
/// endpoints using the OAuth tokens managed by the user's installed
/// Claude Code / Codex CLIs. Reads tokens from the user's keychain
/// (Anthropic) or `~/.codex/auth.json` (Codex), makes the HTTP call,
/// and on a 401 triggers the CLI to refresh its own token by spawning
/// it briefly, then re-reads and retries once.
///
/// We never refresh the token chain ourselves — Anthropic rotates
/// refresh tokens on every use, so a write from us would invalidate
/// the CLI's stored copy. The CLIs own the refresh state machine
/// end-to-end; we only read the latest tokens they've persisted.
@MainActor
final class EditModeProvider: Sendable {
    /// Selections above this size still proceed but the menu-bar status
    /// surfaces the char count so the user knows it'll take a while.
    static let softCharThreshold = 30_000

    /// Selections above this size are refused before we even hit the
    /// network — keeps edit mode focused on its "edit the bit you have
    /// selected" sweet spot and prevents runaway latency / cost on giant
    /// pastes.
    static let hardCharThreshold = 150_000

    static let systemPrompt = """
        You are an editing assistant. The user's instruction was spoken \
        aloud and converted to text by a speech-to-text model — it may \
        contain transcription errors, missing punctuation, homophone \
        mistakes, or words that don't quite match what was said. \
        Interpret the instruction charitably to capture what the user \
        actually meant, then apply it to the piece of text and return \
        only the edited result with no commentary, no labels, and no \
        surrounding quotes.
        """

    /// Wraps a raw transcript in the `<RAW_STT_OUTPUT>` tags the cleanup
    /// system prompt references.
    static func cleanupUserPrompt(transcript: String) -> String {
        """
        <RAW_STT_OUTPUT>
        \(transcript)
        </RAW_STT_OUTPUT>
        """
    }

    func editText(
        instruction: String,
        selection: String,
        model: EditModeModel
    ) async throws -> String {
        let userPrompt = """
            [Spoken instruction (transcribed):]
            \(instruction)

            ---

            [Text to edit:]
            \(selection)
            """
        return try await invoke(
            model: model,
            systemPrompt: Self.systemPrompt,
            userPrompt: userPrompt
        )
    }

    func cleanupTranscript(
        _ transcript: String,
        model: EditModeModel
    ) async throws -> String {
        try await invoke(
            model: model,
            systemPrompt: CleanupPromptStore.loadOrDefault(),
            userPrompt: Self.cleanupUserPrompt(transcript: transcript)
        )
    }

    // MARK: - Dispatch

    private func invoke(
        model: EditModeModel,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        switch model.oauthProvider {
        case "anthropic":
            return try await invokeAnthropic(
                model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        case "openai-codex":
            return try await invokeCodex(
                model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        default:
            throw OAuthApiClient.Error.unsupportedProvider(model.rawValue)
        }
    }

    private func invokeAnthropic(
        model: EditModeModel,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        var creds = try OAuthCredentialStore.anthropic()
        do {
            return try await OAuthApiClient.sendAnthropic(
                accessToken: creds.accessToken,
                model: model.rawValue,
                systemPrompt: systemPrompt,
                userText: userPrompt
            )
        } catch OAuthApiClient.Error.unauthorized {
            // Stale access token — refresh via the CLI, re-read, retry once.
            try await OAuthRefreshTrigger.anthropic()
            creds = try OAuthCredentialStore.anthropic()
            return try await OAuthApiClient.sendAnthropic(
                accessToken: creds.accessToken,
                model: model.rawValue,
                systemPrompt: systemPrompt,
                userText: userPrompt
            )
        }
    }

    private func invokeCodex(
        model: EditModeModel,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        var creds = try OAuthCredentialStore.openAICodex()
        do {
            return try await OAuthApiClient.sendCodex(
                accessToken: creds.accessToken,
                accountId: creds.accountId,
                model: model.rawValue,
                systemPrompt: systemPrompt,
                userText: userPrompt,
                reasoningEffort: model.reasoningEffort
            )
        } catch OAuthApiClient.Error.unauthorized {
            try await OAuthRefreshTrigger.codex()
            creds = try OAuthCredentialStore.openAICodex()
            return try await OAuthApiClient.sendCodex(
                accessToken: creds.accessToken,
                accountId: creds.accountId,
                model: model.rawValue,
                systemPrompt: systemPrompt,
                userText: userPrompt,
                reasoningEffort: model.reasoningEffort
            )
        }
    }
}
