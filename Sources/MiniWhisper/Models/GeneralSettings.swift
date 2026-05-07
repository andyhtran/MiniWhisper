import Foundation

/// Catch-all bag for top-level user preferences that don't have their
/// own focused settings type yet (formatting, edit-mode, VAD, etc.
/// each own theirs). Currently just the error-toast knob; expand as
/// new "General" rows land.
enum GeneralSettings {
    private enum Keys {
        static let errorToastsEnabled = "GeneralErrorToastsEnabled"
    }

    /// When false, `ToastWindowController.showError` becomes a no-op.
    /// Default-on so existing installs (and fresh ones) experience no
    /// change until the user explicitly opts out.
    static var errorToastsEnabled: Bool {
        get { UserDefaults.standard.defaultsToTrue(forKey: Keys.errorToastsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.errorToastsEnabled) }
    }
}
