import Foundation

/// Preference for the client-side VAD preprocessing step applied between
/// recording and upload. Default OFF — only applies to Custom (remote) mode
/// and users opt in explicitly via the toggle that appears in that mode.
enum VADSettings {
    private static let key = "VADPreprocessingEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
