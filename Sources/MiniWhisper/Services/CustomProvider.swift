import Foundation

@MainActor
final class CustomProvider: Sendable {
    func transcribe(audioURL: URL, settings: CustomProviderSettings) async throws -> TranscriptionResult {
        guard settings.isConfigured else {
            throw CustomProviderError.notConfigured
        }

        guard let url = URL(string: settings.endpointURL) else {
            throw CustomProviderError.invalidEndpoint
        }

        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = buildMultipartBody(audioData: audioData, modelName: settings.modelName, boundary: boundary)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomProviderError.serverError(0, "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error message"
            throw CustomProviderError.serverError(httpResponse.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = decoded.language ?? "en"
        let duration = decoded.duration ?? 0

        return TranscriptionResult(
            text: text,
            segments: [TranscriptionSegment(start: 0, end: duration, text: text, words: nil)],
            language: language,
            duration: duration,
            model: settings.modelName
        )
    }

    private func buildMultipartBody(audioData: Data, modelName: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(modelName.data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("json".data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("0".data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
}

enum CustomProviderError: LocalizedError {
    case notConfigured
    case invalidEndpoint
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Custom endpoint not configured"
        case .invalidEndpoint: return "Invalid endpoint URL"
        case .serverError(let code, let message): return "Server error (HTTP \(code)): \(message)"
        }
    }
}
