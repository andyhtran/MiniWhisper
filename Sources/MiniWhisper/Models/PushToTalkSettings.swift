import Foundation

/// Preference for the toggle-recording shortcut's press behavior. Default
/// OFF (toggle: press to start, press again to stop) — users opt into
/// push-to-talk (hold to record, release to stop) explicitly via the
/// toggle in General settings.
enum PushToTalkSettings {
    private static let key = "PushToTalkEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
