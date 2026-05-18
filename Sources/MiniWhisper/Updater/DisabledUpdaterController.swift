import Foundation

private let autoUpdateKey = "autoUpdateEnabled"

@MainActor
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
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
