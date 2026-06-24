import Foundation

@MainActor
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool {
        get { UpdaterDefaults.savedAutoUpdateEnabled() }
        set { UpdaterDefaults.setAutoUpdateEnabled(newValue) }
    }
    let isAvailable: Bool = false
    let unavailableReason: String?
    let updateStatus = UpdateStatus()

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_ sender: Any?) {}
}
