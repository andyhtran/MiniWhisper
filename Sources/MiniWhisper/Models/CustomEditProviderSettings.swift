import Foundation

/// User-supplied configuration for the Custom edit-model backend — an
/// OpenAI-compatible chat-completions endpoint reached over plain HTTP.
/// Mirrors `CustomProviderSettings` (the transcription side) field for
/// field, but keyed separately so the two custom backends can be
/// configured independently.
struct CustomEditProviderSettings: Codable, Equatable, Sendable {
    var endpointURL: String
    var apiKey: String
    /// Chat-completions model name, e.g. `gpt-4o-mini`. Sent verbatim in
    /// the JSON request body.
    var modelName: String

    var isConfigured: Bool {
        !endpointURL.isEmpty && !modelName.isEmpty
    }

    static let empty = CustomEditProviderSettings(endpointURL: "", apiKey: "", modelName: "")

    private static let storageKey = "CustomEditProviderSettings"

    static func load() -> CustomEditProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(CustomEditProviderSettings.self, from: data)
        else {
            return .empty
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
