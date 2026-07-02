import Foundation

@MainActor
protocol UpdaterProviding: AnyObject, Sendable {
    var automaticallyChecksForUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateStatus: UpdateStatus { get }
    func checkForUpdates(_ sender: Any?)
}

@MainActor
@Observable
final class UpdateStatus {
    static let disabled = UpdateStatus()
    /// An update has been downloaded and is ready to install.
    var isUpdateReady: Bool
    /// A scheduled check found an update but the alert was intentionally not
    /// shown (gentle reminders); the badge/banner point the user at it.
    var updateAvailable: Bool = false
    var availableVersion: String?

    /// Drives the status-item badge and the menu banner.
    var needsUserAttention: Bool { updateAvailable || isUpdateReady }

    init(isUpdateReady: Bool = false) {
        self.isUpdateReady = isUpdateReady
    }
}

/// Shared between the Sparkle controller (posts) and AppDelegate (handles the
/// tap), which compile under different flags.
enum UpdateNotification {
    static let identifier = "sparkle-update-available"
}
