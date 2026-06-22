import Foundation

final class FnStateMachine: @unchecked Sendable {
    enum FnEventResult {
        case none
        case fnKeyUp
        case usedAsModifier
    }

    private let lock = NSLock()
    private(set) var isFnKeyDown = false
    private var fnDownTimestamp: UInt64 = 0
    private var usedAsModifier = false
    private var activeFnOnlyShortcut: CustomShortcutName?

    /// A down-state this stale can only mean macOS dropped the matching keyUp.
    private let stuckDownThresholdNs: UInt64 = 5_000_000_000  // 5s

    func processFnKeyDown(captureTime: CFAbsoluteTime, hwTimestamp: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Stuck-state recovery must run before the re-entry guard: macOS
        // sometimes drops the Fn keyUp (app switches, sleep/wake), leaving
        // isFnKeyDown stuck true — exactly the case where the guard below
        // would otherwise swallow this press.
        if isFnKeyDown, fnDownTimestamp > 0,
            hwTimestamp - fnDownTimestamp > stuckDownThresholdNs
        {
            isFnKeyDown = false
            usedAsModifier = false
        }

        guard !isFnKeyDown else { return false }

        isFnKeyDown = true
        fnDownTimestamp = hwTimestamp
        usedAsModifier = false
        return true
    }

    func processFnKeyUp(captureTime: CFAbsoluteTime, hwTimestamp: UInt64) -> FnEventResult {
        lock.lock()
        defer { lock.unlock() }

        guard isFnKeyDown else { return .none }

        isFnKeyDown = false

        if usedAsModifier {
            usedAsModifier = false
            return .usedAsModifier
        }

        // Hold duration is deliberately irrelevant: press-and-hold-then-
        // release toggles the same as a quick tap.
        return .fnKeyUp
    }

    func markUsedAsModifier() -> CustomShortcutName? {
        lock.lock()
        defer { lock.unlock() }
        usedAsModifier = true
        let active = activeFnOnlyShortcut
        activeFnOnlyShortcut = nil
        return active
    }

    func setActiveFnOnlyShortcut(_ name: CustomShortcutName) {
        lock.lock()
        activeFnOnlyShortcut = name
        lock.unlock()
    }

    func clearActiveFnOnlyShortcut() -> CustomShortcutName? {
        lock.lock()
        defer { lock.unlock() }
        let name = activeFnOnlyShortcut
        activeFnOnlyShortcut = nil
        return name
    }

    func reset() {
        lock.lock()
        isFnKeyDown = false
        fnDownTimestamp = 0
        usedAsModifier = false
        activeFnOnlyShortcut = nil
        lock.unlock()
    }
}
