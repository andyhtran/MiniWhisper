import Foundation
import Testing
import SwiftUI
@testable import MiniWhisper

@Suite("Updater factory")
@MainActor
struct UpdaterFactoryTests {
    @Test func disabledUpdaterReportsUnavailable() {
        let updater = DisabledUpdaterController(unavailableReason: "test reason")
        #expect(!updater.isAvailable)
        #expect(updater.unavailableReason == "test reason")
        #expect(updater.updateViewModel.state.isIdle)
    }

    @Test func disabledUpdaterCheckIsNoop() {
        let updater = DisabledUpdaterController()
        updater.checkForUpdates(nil)
        #expect(updater.updateViewModel.state.isIdle)
    }

    @Test func updaterEnvironmentStoresInjectedController() throws {
        let updater = DisabledUpdaterController()
        var values = EnvironmentValues()
        values.updaterController = updater

        let stored = try #require(values.updaterController)
        #expect(stored === updater)
    }

    @Test func autoUpdateDefaultsToEnabledWhenNoPreferenceExists() throws {
        try withIsolatedDefaults { defaults in
            #expect(UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
        }
    }

    @Test func autoUpdatePreferenceUsesSparkleKeyWhenLegacyKeyIsMissing() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: UpdaterDefaults.sparkleEnableAutomaticChecksKey)

            #expect(!UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
        }
    }

    @Test func autoUpdatePreferenceWritesLegacyAndSparkleKeys() throws {
        try withIsolatedDefaults { defaults in
            UpdaterDefaults.setAutoUpdateEnabled(false, in: defaults)

            #expect(!defaults.bool(forKey: UpdaterDefaults.appAutomaticUpdateChecksEnabledKey))
            #expect(!defaults.bool(forKey: UpdaterDefaults.sparkleEnableAutomaticChecksKey))
        }
    }

    @Test func automaticDownloadsMigrationPreservesChecksAndDisablesDownloads() throws {
        try withIsolatedDefaults { defaults in
            UpdaterDefaults.setAutoUpdateEnabled(true, in: defaults)
            defaults.set(true, forKey: UpdaterDefaults.sparkleAutomaticallyUpdateKey)

            UpdaterDefaults.disableAutomaticDownloads(in: defaults)

            #expect(UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
            #expect(!defaults.bool(forKey: UpdaterDefaults.sparkleAutomaticallyUpdateKey))
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "MiniWhisperTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
