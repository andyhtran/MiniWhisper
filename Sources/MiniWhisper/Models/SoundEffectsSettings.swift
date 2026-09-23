import Foundation

/// Preference for the brief start/stop audio cue played around a recording.
/// Default OFF — users opt in explicitly via the toggle in General settings,
/// same convention as `VADSettings`.
enum SoundEffectsSettings {
    private static let key = "RecordingSoundEffectsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
