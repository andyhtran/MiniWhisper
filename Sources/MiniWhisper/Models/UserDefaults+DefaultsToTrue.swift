import Foundation

extension UserDefaults {
    /// Reads a Bool that defaults to `true` when the key is absent — so an
    /// existing install that pre-dates the knob still gets on-by-default
    /// behavior on first read instead of the `bool(forKey:)` zero-value.
    func defaultsToTrue(forKey key: String) -> Bool {
        if object(forKey: key) == nil { return true }
        return bool(forKey: key)
    }
}
