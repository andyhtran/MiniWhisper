import Foundation

/// Edit-mode backend that posts directly to a user-supplied
/// OpenAI-compatible chat-completions endpoint. Mirrors the role
/// `CustomProvider` plays for transcription — the user pastes a URL,
/// API key, and model name; we POST JSON and parse the standard
/// `choices[0].message.content` response.
@MainActor
final class CustomEditProvider: Sendable {
    nonisolated static func normalizeEndpoint(_ input: String) -> String {
        CustomEndpointNormalizer.normalize(input, canonicalPath: "/v1/chat/completions")
    }

    func editText(
        instruction: String,
        selection: String,
        settings: CustomEditProviderSettings
    ) async throws -> String {
        let userPrompt = """
            [Spoken instruction (transcribed):]
            \(instruction)

            ---

            [Text to edit:]
            \(selection)
            """
        return try await complete(
            systemPrompt: EditModeProvider.systemPrompt,
            userPrompt: userPrompt,
            settings: settings
        )
    }

    func cleanupTranscript(
        _ transcript: String,
        settings: CustomEditProviderSettings
    ) async throws -> String {
        let userPrompt = EditModeProvider.cleanupUserPrompt(transcript: transcript)
        return try await complete(
            systemPrompt: CleanupPromptStore.loadOrDefault(),
            userPrompt: userPrompt,
            settings: settings
        )
    }

    private func complete(
        systemPrompt: String,
        userPrompt: String,
        settings: CustomEditProviderSettings
    ) async throws -> String {
        guard settings.isConfigured else {
            throw CustomEditProviderError.notConfigured
        }

        let normalized = Self.normalizeEndpoint(settings.endpointURL)
        guard let url = URL(string: normalized) else {
            throw CustomEditProviderError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: settings.modelName,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ],
            temperature: 0
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomEditProviderError.serverError(0, "Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error message"
            throw CustomEditProviderError.serverError(httpResponse.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let text = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw CustomEditProviderError.emptyResponse
        }
        return text
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

enum CustomEditProviderError: LocalizedError {
    case notConfigured
    case invalidEndpoint
    case serverError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Custom edit endpoint not configured"
        case .invalidEndpoint: return "Invalid endpoint URL"
        case .serverError(let code, let message):
            return "Server error (HTTP \(code)): \(message)"
        case .emptyResponse: return "Custom edit endpoint returned no text."
        }
    }
}
