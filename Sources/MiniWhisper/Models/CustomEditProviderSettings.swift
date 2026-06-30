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

    private enum CodingKeys: String, CodingKey {
        case endpointURL
        case apiKey
        case modelName
    }

    init(endpointURL: String, apiKey: String, modelName: String) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.modelName = modelName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpointURL = try container.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpointURL, forKey: .endpointURL)
        try container.encode(modelName, forKey: .modelName)
    }

    static func load() -> CustomEditProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(CustomEditProviderSettings.self, from: data)
        else {
            return .empty.withKeychainAPIKey()
        }

        let migratedKey = settings.apiKey
        let keychainKey = CustomProviderAPIKeyStore.editKey()
        if keychainKey.isEmpty {
            settings.apiKey = migratedKey
            if !migratedKey.isEmpty,
               CustomProviderAPIKeyStore.saveEditKey(migratedKey) {
                settings.saveMetadataOnly()
            }
        } else {
            settings.apiKey = keychainKey
            if !migratedKey.isEmpty {
                settings.saveMetadataOnly()
            }
        }
        return settings
    }

    func save() {
        guard CustomProviderAPIKeyStore.saveEditKey(apiKey) else { return }
        saveMetadataOnly()
    }

    private func saveMetadataOnly() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func withKeychainAPIKey() -> CustomEditProviderSettings {
        var settings = self
        settings.apiKey = CustomProviderAPIKeyStore.editKey()
        return settings
    }
}
