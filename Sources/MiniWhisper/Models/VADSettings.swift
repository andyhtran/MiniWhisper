import Foundation

/// Preference for the client-side VAD preprocessing step applied between
/// recording and transcription. Default OFF — users opt in explicitly via
/// the toggle in General settings.
enum VADSettings {
    private static let key = "VADPreprocessingEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
