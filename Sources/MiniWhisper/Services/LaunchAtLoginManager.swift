import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool {
        didSet {
            if isEnabled {
                enableLaunchAtLogin()
            } else {
                disableLaunchAtLogin()
            }
        }
    }

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    private func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            Task { @MainActor in
                self.isEnabled = false
            }
        }
    }

    private func disableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            return
        }
    }

    func refresh() {
        let newStatus = SMAppService.mainApp.status == .enabled
        if newStatus != isEnabled {
            _isEnabled = Published(wrappedValue: newStatus)
        }
    }
}
