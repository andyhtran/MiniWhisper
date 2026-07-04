import Foundation

@MainActor
protocol UpdaterProviding: AnyObject, Sendable {
    var automaticallyChecksForUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateViewModel: UpdateViewModel { get }
    func checkForUpdates(_ sender: Any?)
}

/// Shared between the Sparkle driver (posts) and AppDelegate (handles the
/// tap), which compile under different flags.
enum UpdateNotification {
    static let identifier = "sparkle-update-available"
}
