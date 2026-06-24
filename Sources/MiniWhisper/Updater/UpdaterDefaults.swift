import Foundation

enum UpdaterDefaults {
    static let appAutomaticUpdateChecksEnabledKey = "autoUpdateEnabled"
    static let sparkleEnableAutomaticChecksKey = "SUEnableAutomaticChecks"
    static let sparkleAutomaticallyUpdateKey = "SUAutomaticallyUpdate"

    static func savedAutoUpdateEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: appAutomaticUpdateChecksEnabledKey) != nil {
            return defaults.bool(forKey: appAutomaticUpdateChecksEnabledKey)
        }
        if defaults.object(forKey: sparkleEnableAutomaticChecksKey) != nil {
            return defaults.bool(forKey: sparkleEnableAutomaticChecksKey)
        }
        return true
    }

    static func setAutoUpdateEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: appAutomaticUpdateChecksEnabledKey)
        defaults.set(enabled, forKey: sparkleEnableAutomaticChecksKey)
    }

    static func disableAutomaticDownloads(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: sparkleAutomaticallyUpdateKey)
    }
}
