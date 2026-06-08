import Foundation

@MainActor
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.object(forKey: UpdaterDefaults.autoUpdateEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: UpdaterDefaults.autoUpdateEnabledKey) }
    }
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = false
    let unavailableReason: String?
    let updateStatus = UpdateStatus()

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_ sender: Any?) {}
}
