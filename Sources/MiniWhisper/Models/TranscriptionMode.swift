import Foundation

enum TranscriptionMode: String, Codable, Sendable {
    case english
    case multilingual
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
