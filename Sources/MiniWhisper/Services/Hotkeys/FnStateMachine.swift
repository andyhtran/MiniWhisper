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

    private let maxTapDurationNs: UInt64 = 500_000_000  // 0.5s

    func processFnKeyDown(captureTime: CFAbsoluteTime, hwTimestamp: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFnKeyDown else { return false }

        // Detect stuck state: macOS sometimes drops the Fn keyUp event
        // (e.g. during app switches or sleep/wake), leaving isFnKeyDown stuck true.
        if fnDownTimestamp > 0 {
            let elapsed = hwTimestamp - fnDownTimestamp
            if elapsed > 5_000_000_000 {
                isFnKeyDown = false
                usedAsModifier = false
            }
        }

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

        let duration = hwTimestamp - fnDownTimestamp
        if duration <= maxTapDurationNs {
            return .fnKeyUp
        }

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
