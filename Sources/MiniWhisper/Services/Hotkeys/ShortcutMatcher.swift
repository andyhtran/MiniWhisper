import Foundation
import AppKit

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

    func findMatch(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, fnPressed: Bool) -> MatchResult? {
        lock.lock()
        let current = shortcuts
        lock.unlock()

        for (name, shortcut) in current {
            if shortcut.isFnOnly { continue }
            if shortcut.matches(keyCode: keyCode, modifiers: modifiers, fnPressed: fnPressed) {
                return MatchResult(name: name)
            }
        }
        return nil
    }

    func findByKeyCode(_ keyCode: UInt16) -> MatchResult? {
        lock.lock()
        let current = shortcuts
        lock.unlock()

        for (name, shortcut) in current {
            if shortcut.keyCode == keyCode {
                return MatchResult(name: name)
            }
        }
        return nil
    }

    func findFnOnlyShortcut() -> MatchResult? {
        lock.lock()
        let current = shortcuts
        lock.unlock()

        for (name, shortcut) in current {
            if shortcut.isFnOnly {
                return MatchResult(name: name)
            }
        }
        return nil
    }

    func hasFnOnlyShortcut() -> Bool {
        findFnOnlyShortcut() != nil
    }
}
