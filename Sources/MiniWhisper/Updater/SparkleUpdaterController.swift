#if canImport(Sparkle) && ENABLE_SPARKLE
import AppKit
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding {
    private let driver: UpdateDriver
    private let updater: SPUUpdater
    private var started = false
    let unavailableReason: String? = nil

    var updateViewModel: UpdateViewModel { driver.viewModel }

    init(savedAutoUpdate: Bool) {
        let driver = UpdateDriver(viewModel: UpdateViewModel())
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil)
        super.init()

        UpdaterDefaults.disableAutomaticDownloads()
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = false
        startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            UpdaterDefaults.setAutoUpdateEnabled(newValue)
            UpdaterDefaults.disableAutomaticDownloads()
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = false
        }
    }

    var isAvailable: Bool { true }

    func checkForUpdates(_ sender: Any?) {
        guard started else {
            startUpdater()
            if started { updater.checkForUpdates() }
            return
        }

        let state = updateViewModel.state
        guard state.allowsManualCheck else { return }

        guard !state.isIdle else {
            updater.checkForUpdates()
            return
        }

        // Only terminal result banners reach this path. Acknowledge them
        // first; Sparkle needs a beat to settle before it accepts a new check.
        state.cancel()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.updater.checkForUpdates()
        }
    }

    private func startUpdater() {
        do {
            try updater.start()
            started = true
        } catch {
            // Start only fails on configuration problems (e.g. a broken feed
            // URL); surface it in the banner rather than dying silently.
            driver.viewModel.state = .failed(.init(
                message: error.localizedDescription,
                dismiss: { [weak self] in
                    self?.updateViewModel.state = .idle
                }))
        }
    }
}
#endif
