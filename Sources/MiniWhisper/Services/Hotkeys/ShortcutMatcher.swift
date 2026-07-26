import Foundation

/// Holds the persisted shortcut set and answers the one question the modifier
/// tap still needs at event time. Key chords are matched by the hot-key
/// registration itself, so no per-event comparison happens for them.
final class ShortcutMatcher: @unchecked Sendable {
    struct MatchResult {
        let name: CustomShortcutName
    }

    private var shortcuts: [CustomShortcutName: CustomShortcut] = [:]
    private let lock = NSLock()

    init() {
        reloadShortcuts()
    }

    func reloadShortcuts() {
        let loaded = CustomShortcutStorage.loadAll()
        lock.lock()
        shortcuts = loaded
        lock.unlock()
    }

    func getAllShortcuts() -> [CustomShortcutName: CustomShortcut] {
        lock.lock()
        defer { lock.unlock() }
        return shortcuts
    }

    /// Scanned in declaration order rather than dictionary order: if a user has
    /// bound more than one shortcut to the bare modifier, the same one must win
    /// every time, or which action fires would vary between presses.
    func findFnOnlyShortcut() -> MatchResult? {
        lock.lock()
        let current = shortcuts
        lock.unlock()

        for name in CustomShortcutName.allCases where current[name]?.isFnOnly == true {
            return MatchResult(name: name)
        }
        return nil
    }
}
