#if canImport(Sparkle) && ENABLE_SPARKLE
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil)
    let updateStatus = UpdateStatus()
    let unavailableReason: String? = nil

    init(savedAutoUpdate: Bool) {
        super.init()
        let updater = self.controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = savedAutoUpdate
        self.controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.controller.updater.automaticallyChecksForUpdates }
        set { self.controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { self.controller.updater.automaticallyDownloadsUpdates }
        set { self.controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var isAvailable: Bool { true }

    func checkForUpdates(_ sender: Any?) {
        self.controller.checkForUpdates(sender)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.updateStatus.isUpdateReady = true
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
