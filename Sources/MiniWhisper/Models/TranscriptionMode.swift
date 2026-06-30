import Foundation

enum TranscriptionMode: String, Codable, Sendable {
    // Raw value kept as "english" to preserve existing UserDefaults entries
    // from earlier versions. The case name is intentionally generic so the
    // underlying model can be swapped (currently Parakeet) without another
    // rename cascade.
    case `default` = "english"
    case multilingual
    case custom

    var modelDisplayName: String {
        switch self {
        case .default: return "Parakeet"
        case .multilingual: return "Whisper"
        case .custom: return "Custom"
        }
    }
}

struct TranscriptionModeStorage: Sendable {
    private static let storageKey = "TranscriptionMode"

    static func load() -> TranscriptionMode {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let mode = TranscriptionMode(rawValue: raw) else {
            return .default
        }
        return mode
    }

    static func save(_ mode: TranscriptionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}

struct CustomProviderSettings: Codable, Equatable, Sendable {
    var endpointURL: String
    var apiKey: String
    /// Transcription (speech-to-text) model name, e.g. `whisper-large-v3`.
    var modelName: String

    var isConfigured: Bool {
        !endpointURL.isEmpty && !modelName.isEmpty
    }

    static let empty = CustomProviderSettings(endpointURL: "", apiKey: "", modelName: "")

    private static let storageKey = "CustomProviderSettings"

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

    static func load() -> CustomProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(CustomProviderSettings.self, from: data) else {
            return .empty.withKeychainAPIKey()
        }

        let migratedKey = settings.apiKey
        let keychainKey = CustomProviderAPIKeyStore.transcriptionKey()
        if keychainKey.isEmpty {
            settings.apiKey = migratedKey
            if !migratedKey.isEmpty,
               CustomProviderAPIKeyStore.saveTranscriptionKey(migratedKey) {
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
        guard CustomProviderAPIKeyStore.saveTranscriptionKey(apiKey) else { return }
        saveMetadataOnly()
    }

    private func saveMetadataOnly() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func withKeychainAPIKey() -> CustomProviderSettings {
        var settings = self
        settings.apiKey = CustomProviderAPIKeyStore.transcriptionKey()
        return settings
    }
}
