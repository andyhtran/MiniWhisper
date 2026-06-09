import Foundation

/// Detects double-taps (and single clean taps) of a modifier key from
/// flagsChanged press/release pairs. Pure and lock-guarded so it can run on the
/// event-tap thread and be unit-tested with no event tap at all — the same
/// discipline as `FnStateMachine`.
///
/// A "clean tap" is a press then release of one modifier within `maxTapDuration`
/// with no other key pressed in between (so ⌥+C combos and long holds don't
/// count). Two clean taps of the *same* key within `doubleTapWindow` is a
/// double-tap. Timestamps are wall-clock seconds (`CFAbsoluteTimeGetCurrent()`)
/// to avoid the mach-timebase ambiguity of `CGEvent.timestamp`.
final class DoubleTapDetector: @unchecked Sendable {
    enum Result: Equatable {
        case none
        case tap        // one clean tap completed (not part of a double-tap)
        case doubleTap  // this tap was the second of a double-tap of the same key
    }

    private let lock = NSLock()
    private let maxTapDuration: TimeInterval
    private let doubleTapWindow: TimeInterval

    // The modifier currently held down (if any) and when it went down.
    private var downKeyCode: UInt16?
    private var downTime: TimeInterval = 0
    private var usedAsModifier = false

    // The last clean tap, for pairing into a double-tap.
    private var lastTapKeyCode: UInt16?
    private var lastTapTime: TimeInterval = 0

    init(maxTapDuration: TimeInterval = 0.4, doubleTapWindow: TimeInterval = 0.3) {
        self.maxTapDuration = maxTapDuration
        self.doubleTapWindow = doubleTapWindow
    }

    /// A modifier key's flag turned on (key went down).
    func modifierDown(keyCode: UInt16, time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        downKeyCode = keyCode
        downTime = time
        usedAsModifier = false
    }

    /// Another key was pressed while a modifier was held — so the modifier is
    /// being used as part of a combo, not tapped. Also breaks any pending
    /// double-tap chain (a double-tap must be two *consecutive* modifier taps).
    func noteOtherKeyDown() {
        lock.lock(); defer { lock.unlock() }
        usedAsModifier = true
        lastTapKeyCode = nil
    }

    /// A modifier key's flag turned off (key went up). Returns whether the
    /// press→release was a clean tap, and whether it completed a double-tap.
    func modifierUp(keyCode: UInt16, time: TimeInterval) -> Result {
        lock.lock(); defer { lock.unlock() }

        guard downKeyCode == keyCode else {
            // Release with no matching press we saw (e.g. dropped event / other
            // key still held) — not a tap, and it breaks any chain.
            lastTapKeyCode = nil
            return .none
        }

        let held = time - downTime
        let wasModifier = usedAsModifier
        downKeyCode = nil
        usedAsModifier = false

        guard !wasModifier, held <= maxTapDuration else {
            lastTapKeyCode = nil
            return .none
        }

        if lastTapKeyCode == keyCode, (time - lastTapTime) <= doubleTapWindow {
            lastTapKeyCode = nil  // consume the chain so a 3rd tap starts fresh
            return .doubleTap
        }

        lastTapKeyCode = keyCode
        lastTapTime = time
        return .tap
    }

    /// Forget any pending tap chain (e.g. after a single tap fired an action),
    /// without disturbing an in-progress hold.
    func clearTapChain() {
        lock.lock(); defer { lock.unlock() }
        lastTapKeyCode = nil
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        downKeyCode = nil
        downTime = 0
        usedAsModifier = false
        lastTapKeyCode = nil
        lastTapTime = 0
    }
}
