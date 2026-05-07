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

    static func load() -> CustomProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(CustomProviderSettings.self, from: data) else {
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
