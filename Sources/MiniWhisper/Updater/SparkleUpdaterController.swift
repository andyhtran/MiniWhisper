#if canImport(Sparkle) && ENABLE_SPARKLE
import Foundation
import Sparkle
import UserNotifications

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate
{
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self)
    let updateStatus = UpdateStatus()
    let unavailableReason: String? = nil

    init(savedAutoUpdate: Bool) {
        super.init()
        UpdaterDefaults.disableAutomaticDownloads()
        let updater = self.controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = false
        self.controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.controller.updater.automaticallyChecksForUpdates }
        set {
            UpdaterDefaults.setAutoUpdateEnabled(newValue)
            UpdaterDefaults.disableAutomaticDownloads()
            let updater = self.controller.updater
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = false
        }
    }

    var isAvailable: Bool { true }

    func checkForUpdates(_ sender: Any?) {
        self.controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    // This app is LSUIElement, so it never becomes active; without gentle
    // reminders Sparkle shows scheduled-update alerts behind other apps'
    // windows and users never see them. We suppress the buried alert and
    // surface the update through the status-item badge, the menu banner,
    // and a user notification instead. Tapping any of them re-enters the
    // update session via checkForUpdates, which focuses the alert.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool) -> Bool
    {
        // immediateFocus is true only right after updater start, when Sparkle
        // can show the alert in front — let it. Otherwise we take over.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState)
    {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            self.updateStatus.updateAvailable = true
            self.updateStatus.availableVersion = version
            self.postUpdateAvailableNotification(version: version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            self.clearGentleReminders()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.clearGentleReminders()
        }
    }

    private func postUpdateAvailableNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "MiniWhisper \(version) is available. Click to update."
        let request = UNNotificationRequest(
            identifier: UpdateNotification.identifier, content: content, trigger: nil)
        // If notification permission was denied, this is silently dropped —
        // the badge and menu banner still cover discovery.
        UNUserNotificationCenter.current().add(request)
    }

    private func clearGentleReminders() {
        updateStatus.updateAvailable = false
        updateStatus.availableVersion = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [UpdateNotification.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [UpdateNotification.identifier])
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.updateStatus.isUpdateReady = true
            self.updateStatus.availableVersion = version
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Task { @MainActor in
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState)
    {
        let downloaded = state.stage == .downloaded
        Task { @MainActor in
            switch choice {
            case .install, .skip:
                self.updateStatus.isUpdateReady = false
            case .dismiss:
                self.updateStatus.isUpdateReady = downloaded
            @unknown default:
                self.updateStatus.isUpdateReady = false
            }
        }
    }
}
#endif
