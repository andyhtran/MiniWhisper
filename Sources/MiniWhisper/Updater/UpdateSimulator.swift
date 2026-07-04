#if DEBUG
import Foundation
import UserNotifications

/// Debug-only fake updater that walks the banner UI through scripted update
/// scenarios with realistic pacing — no Sparkle, no signing, no appcast.
///
/// Enable, then launch with `just dev`:
///
///     defaults write com.miniwhisper.dev UpdateSimulatorScenario happy
///
/// Disable:
///
///     defaults delete com.miniwhisper.dev UpdateSimulatorScenario
@MainActor
final class UpdateSimulator: UpdaterProviding {
    enum Scenario: String {
        /// Check Now → update available → Install → download → prepare →
        /// install. A real update terminates and relaunches the app at the
        /// end; the simulator returns to idle instead.
        case happy
        /// An update is "found by a scheduled check" a few seconds after
        /// launch: banner and notification appear without any user action.
        case background
        /// Check Now → "You're up to date" (auto-dismisses).
        case notfound
        /// Check Now → failure banner with Retry.
        case error
    }

    static let defaultsKey = "UpdateSimulatorScenario"

    static func configured() -> UpdateSimulator? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let scenario = Scenario(rawValue: raw)
        else { return nil }
        return UpdateSimulator(scenario: scenario)
    }

    let updateViewModel = UpdateViewModel()
    let isAvailable = true
    let unavailableReason: String? = nil

    private let scenario: Scenario
    private var task: Task<Void, Never>?

    var automaticallyChecksForUpdates: Bool {
        get { UpdaterDefaults.savedAutoUpdateEnabled() }
        set { UpdaterDefaults.setAutoUpdateEnabled(newValue) }
    }

    init(scenario: Scenario) {
        self.scenario = scenario
        guard scenario == .background else { return }
        run {
            try await Task.sleep(for: .seconds(3))
            self.offerUpdate(notify: true)
        }
    }

    func checkForUpdates(_ sender: Any?) {
        run {
            self.updateViewModel.state = .checking(.init(
                cancel: { [weak self] in self?.reset() }))
            try await Task.sleep(for: .seconds(1.2))

            switch self.scenario {
            case .happy, .background:
                self.offerUpdate(notify: false)

            case .notfound:
                self.updateViewModel.state = .notFound(.init(
                    acknowledge: { [weak self] in self?.reset() }))
                // Mirror the real driver's auto-dismiss.
                try await Task.sleep(for: .seconds(5))
                self.updateViewModel.state = .idle

            case .error:
                self.updateViewModel.state = .failed(.init(
                    message: "The update feed could not be reached (simulated).",
                    dismiss: { [weak self] in self?.reset() }))
            }
        }
    }

    private func offerUpdate(notify: Bool) {
        updateViewModel.state = .updateAvailable(.init(
            version: "99.0",
            byteCount: 12_800_000,
            install: { [weak self] in self?.install() },
            dismiss: { [weak self] in self?.reset() }))
        if notify {
            let content = UNMutableNotificationContent()
            content.title = "Update Available"
            content.body = "MiniWhisper 99.0 is available. Click to update."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UpdateNotification.identifier,
                    content: content, trigger: nil))
        }
    }

    private func install() {
        run {
            let total: UInt64 = 12_800_000
            let cancel: () -> Void = { [weak self] in self?.reset() }
            self.updateViewModel.state = .downloading(.init(
                cancel: cancel, expectedLength: nil, receivedLength: 0))
            // Brief indeterminate stretch before the content length arrives,
            // like a real download.
            try await Task.sleep(for: .milliseconds(500))
            var received: UInt64 = 0
            while received < total {
                received = min(total, received + 320_000)
                self.updateViewModel.state = .downloading(.init(
                    cancel: cancel, expectedLength: total,
                    receivedLength: received))
                try await Task.sleep(for: .milliseconds(100))
            }
            for step in 1...15 {
                self.updateViewModel.state = .extracting(.init(
                    progress: Double(step) / 15))
                try await Task.sleep(for: .milliseconds(100))
            }
            self.updateViewModel.state = .installing
            try await Task.sleep(for: .seconds(2.5))
            self.reset()
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        task = Task {
            try? await body()
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        updateViewModel.state = .idle
    }
}
#endif
