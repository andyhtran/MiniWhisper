import Foundation

final class FnStateMachine: @unchecked Sendable {
    enum FnEventResult {
        case none
        case fnKeyUp
        case usedAsModifier
    }

    private let lock = NSLock()
    private var fnDown = false
    private var fnDownTimestamp: UInt64 = 0
    private var usedAsModifier = false
    private var activeFnOnlyShortcut: CustomShortcutName?
    private var pressWasSwallowed = false

    /// A down-state this stale can only mean macOS dropped the matching keyUp.
    private let stuckDownThresholdNs: UInt64 = 5_000_000_000  // 5s

    /// Read from the main actor as well as the tap threads, so it goes through
    /// the lock like every other field here.
    var isFnKeyDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fnDown
    }

    /// The in-flight bare-modifier shortcut, left in place.
    ///
    /// Distinct from `clearActiveFnOnlyShortcut()`, which hands over ownership
    /// of completing the press; this is for deciding whether a press is still
    /// being held by the modifier tap at all.
    var activeFnOnlyShortcutName: CustomShortcutName? {
        lock.lock()
        defer { lock.unlock() }
        return activeFnOnlyShortcut
    }

    func processFnKeyDown(captureTime: CFAbsoluteTime, hwTimestamp: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Stuck-state recovery must run before the re-entry guard: macOS
        // sometimes drops the Fn keyUp (app switches, sleep/wake), leaving
        // fnDown stuck true — exactly the case where the guard below
        // would otherwise swallow this press.
        //
        // `activeFnOnlyShortcut` deliberately survives: the press it names was
        // never released, and only the caller can complete it. Callers must
        // drain it when a press is accepted, or the recovered press collides
        // with the abandoned one and neither fires.
        if fnDown, fnDownTimestamp > 0,
            hwTimestamp - fnDownTimestamp > stuckDownThresholdNs
        {
            fnDown = false
            usedAsModifier = false
        }

        guard !fnDown else { return false }

        fnDown = true
        fnDownTimestamp = hwTimestamp
        usedAsModifier = false
        return true
    }

    func processFnKeyUp(captureTime: CFAbsoluteTime, hwTimestamp: UInt64) -> FnEventResult {
        lock.lock()
        defer { lock.unlock() }

        guard fnDown else { return .none }

        fnDown = false

        if usedAsModifier {
            usedAsModifier = false
            return .usedAsModifier
        }

        // Hold duration is deliberately irrelevant: press-and-hold-then-
        // release toggles the same as a quick tap.
        return .fnKeyUp
    }

    /// Remembers whether this press was hidden from the rest of the system.
    ///
    /// The release has to make the same choice: macOS triggers its own "press 🌐
    /// to…" action on the *release*, so a swallowed press followed by a
    /// delivered release fires exactly the system action the press was hidden to
    /// avoid.
    func recordPressSwallowed(_ swallowed: Bool) {
        lock.lock()
        pressWasSwallowed = swallowed
        lock.unlock()
    }

    /// Whether the press this release completes was swallowed. Consumed, so a
    /// release with no press behind it is never swallowed on the strength of an
    /// older one.
    func consumePressSwallowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let swallowed = pressWasSwallowed
        pressWasSwallowed = false
        return swallowed
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
        fnDown = false
        fnDownTimestamp = 0
        usedAsModifier = false
        activeFnOnlyShortcut = nil
        pressWasSwallowed = false
        lock.unlock()
    }
}
