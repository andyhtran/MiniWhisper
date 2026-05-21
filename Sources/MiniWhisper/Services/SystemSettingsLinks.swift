import AppKit
import Foundation

@MainActor
enum SystemSettingsLinks {
    static func openMenuBarSettings() {
        guard let url = URL(string: menuBarSettingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static var menuBarSettingsURLString: String {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVersion >= 26 {
            return "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension*menubar"
        }
        return "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
    }
}
