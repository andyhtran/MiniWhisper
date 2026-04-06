import Foundation

enum TranscriptionMode: String, Codable, Sendable {
    case english
    case multilingual
    case custom

    var modelDisplayName: String {
        switch self {
        case .english: return "Parakeet"
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
            return .english
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
