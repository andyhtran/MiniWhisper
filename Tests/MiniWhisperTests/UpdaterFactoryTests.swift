import Testing
@testable import MiniWhisper

@Suite("Updater factory")
@MainActor
struct UpdaterFactoryTests {
    @Test func disabledUpdaterReportsUnavailable() {
        let updater = DisabledUpdaterController(unavailableReason: "test reason")
        #expect(!updater.isAvailable)
        #expect(updater.unavailableReason == "test reason")
        #expect(!updater.updateStatus.isUpdateReady)
    }

    @Test func disabledUpdaterCheckIsNoop() {
        let updater = DisabledUpdaterController()
        updater.checkForUpdates(nil)
    }

    @Test func updateStatusDefaultsToNotReady() {
        let status = UpdateStatus()
        #expect(!status.isUpdateReady)
    }

    @Test func disabledStaticInstanceIsNotReady() {
        #expect(!UpdateStatus.disabled.isUpdateReady)
    }
}
