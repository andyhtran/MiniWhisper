import Foundation

/// Posts to Anthropic and Codex inference endpoints using the OAuth
/// tokens from `OAuthCredentialStore`. Mirrors the headers and request
/// shape used by the user's installed Claude Code / Codex CLIs —
/// required because the OAuth tokens are subscription-scoped and the
/// edge rejects requests that don't carry the right CLI identity.
enum OAuthApiClient {
    enum Error: LocalizedError {
        case unauthorized(String)
        case serverError(Int, String)
        case malformedResponse(String)
        case emptyResponse
        case unsupportedProvider(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized(let body):
                let suffix = body.isEmpty ? "" : ": \(body)"
                return "OAuth API auth rejected (HTTP 401)\(suffix)"
            case .serverError(let code, let body):
                let suffix = body.isEmpty ? "" : ": \(body)"
                return "OAuth API server error (HTTP \(code))\(suffix)"
            case .malformedResponse(let detail):
                return "OAuth API malformed response: \(detail)"
            case .emptyResponse:
                return "OAuth API returned no text."
            case .unsupportedProvider(let model):
                return "OAuth API doesn't support model \(model)."
            }
        }
    }

    // MARK: - Anthropic

    /// Sentinel system block required when calling the Anthropic
    /// Messages API with an `sk-ant-oat-...` OAuth token. The edge
    /// validates that the first system block matches this exact string
    /// and rejects requests that don't carry it.
    private static let anthropicSentinel =
        "You are Claude Code, Anthropic's official CLI for Claude."

    /// Pinned Claude Code version for the user-agent header. Only matters
    /// that it matches CC's wire format; bumping it occasionally is fine
    /// but not required for the API to accept the request.
    private static let claudeCliVersion = "2.1.75"

    static func sendAnthropic(
        accessToken: String,
        model: String,
        systemPrompt: String,
        userText: String,
        timeoutSeconds: Double = 120
    ) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw Error.malformedResponse("could not construct Anthropic URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(
            "claude-code-20250219,oauth-2025-04-20",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue("claude-cli/\(claudeCliVersion)", forHTTPHeaderField: "user-agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")

        let body = AnthropicMessagesRequest(
            model: model,
            maxTokens: 4096,
            system: [
                .init(type: "text", text: anthropicSentinel),
                .init(type: "text", text: systemPrompt),
            ],
            messages: [.init(role: "user", content: userText)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401: throw Error.unauthorized(prefixBody(data))
        default: throw Error.serverError(http.statusCode, prefixBody(data))
        }

        let decoded: AnthropicMessagesResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        } catch {
            throw Error.malformedResponse(
                "Anthropic JSON decode failed: \(error.localizedDescription)")
        }
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Error.emptyResponse }
        return text
    }

    // MARK: - OpenAI Codex

    /// Posts to ChatGPT-backed Codex Responses endpoint. SSE only — the
    /// backend rejects `stream:false`. We accumulate `output_text.delta`
    /// events into a single string.
    static func sendCodex(
        accessToken: String,
        accountId: String,
        model: String,
        systemPrompt: String,
        userText: String,
        reasoningEffort: String?,
        timeoutSeconds: Double = 120
    ) async throws -> String {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw Error.malformedResponse("could not construct Codex URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var reasoning: CodexResponsesRequest.Reasoning?
        if let effort = reasoningEffort {
            reasoning = .init(effort: effort, summary: "auto")
        }
        let body = CodexResponsesRequest(
            model: model,
            instructions: systemPrompt,
            input: [
                .init(role: "user", content: [.init(type: "input_text", text: userText)])
            ],
            reasoning: reasoning,
            text: .init(verbosity: "low"),
            include: ["reasoning.encrypted_content"],
            store: false,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // Drain body for the error message.
            var bodyData = Data()
            for try await byte in bytes { bodyData.append(byte) }
            let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
            if http.statusCode == 401 {
                throw Error.unauthorized(bodyText.prefixCapped())
            }
            throw Error.serverError(http.statusCode, bodyText.prefixCapped())
        }

        var output = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            // SSE wire format is `data: <json>` lines separated by blank
            // lines. Codex puts the event type inside the JSON payload,
            // not on `event:` lines, so we parse every `data:` and switch
            // on `.type`.
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(CodexSSEEvent.self, from: data) else { continue }
            if event.type == "response.output_text.delta", let delta = event.delta {
                output += delta
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.emptyResponse }
        return trimmed
    }

    // MARK: - Helpers

    private static func prefixBody(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "").prefixCapped()
    }
}

// MARK: - Anthropic wire types

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: [SystemBlock]
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }

    struct SystemBlock: Encodable {
        let type: String
        let text: String
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct AnthropicMessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - Codex wire types

private struct CodexResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputMessage]
    let reasoning: Reasoning?
    let text: TextOptions
    let include: [String]
    let store: Bool
    let stream: Bool

    struct InputMessage: Encodable {
        let role: String
        let content: [Block]
        struct Block: Encodable {
            let type: String
            let text: String
        }
    }

    struct Reasoning: Encodable {
        let effort: String
        let summary: String
    }

    struct TextOptions: Encodable {
        let verbosity: String
    }
}

private struct CodexSSEEvent: Decodable {
    let type: String
    let delta: String?
}

// MARK: - String helpers

private extension String {
    func prefixCapped(_ max: Int = 300) -> String {
        if count <= max { return self }
        return String(prefix(max)) + "…"
    }
}
