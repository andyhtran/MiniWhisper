import Foundation

final class ShortcutHandlerRegistry: @unchecked Sendable {
    typealias ShortcutHandler = @Sendable @MainActor () -> Void
    typealias ShortcutEnabledCheck = @Sendable () -> Bool

    private var keyDownHandlers: [CustomShortcutName: ShortcutHandler] = [:]
    private var keyUpHandlers: [CustomShortcutName: ShortcutHandler] = [:]
    private var enabledChecks: [CustomShortcutName: ShortcutEnabledCheck] = [:]
    private let lock = NSLock()

    func setKeyDownHandler(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        lock.lock()
        keyDownHandlers[name] = handler
        lock.unlock()
    }

    func setKeyUpHandler(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        lock.lock()
        keyUpHandlers[name] = handler
        lock.unlock()
    }

    func setEnabledCheck(for name: CustomShortcutName, check: @escaping ShortcutEnabledCheck) {
        lock.lock()
        enabledChecks[name] = check
        lock.unlock()
    }

    func getKeyDownHandler(for name: CustomShortcutName) -> ShortcutHandler? {
        lock.lock()
        defer { lock.unlock() }
        return keyDownHandlers[name]
    }

    func getKeyUpHandler(for name: CustomShortcutName) -> ShortcutHandler? {
        lock.lock()
        defer { lock.unlock() }
        return keyUpHandlers[name]
    }

    func isEnabled(name: CustomShortcutName) -> Bool {
        lock.lock()
        let check = enabledChecks[name]
        lock.unlock()
        return check?() ?? true
    }
}
