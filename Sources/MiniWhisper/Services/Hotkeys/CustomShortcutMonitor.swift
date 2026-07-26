import AppKit
import CoreGraphics
import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ShortcutMonitor")

/// Routes each configured shortcut to the backend that can serve it.
///
/// Key chords go to Carbon, which keeps this process out of the keystroke
/// delivery path entirely. Only bare-modifier shortcuts (Fn/Globe bound on its
/// own) need an event tap, and that tap sees nothing but `.flagsChanged`.
final class CustomShortcutMonitor: @unchecked Sendable {
    typealias ShortcutHandler = @Sendable @MainActor () -> Void
    typealias ShortcutEnabledCheck = @Sendable () -> Bool

    @MainActor static let shared = CustomShortcutMonitor()

    private let shortcutMatcher: ShortcutMatcher
    private let handlerRegistry: ShortcutHandlerRegistry
    private let fnStateMachine: FnStateMachine
    private let modifierTap: ModifierTapMonitor
    private let keyDownObserver: KeyDownObserver
    private let carbonCenter: CarbonHotKeyCenter

    private var pressTracker = HotKeyPressTracker()
    private let pressLock = NSLock()
    private var running = false
    /// Last reported collisions, so a refresh that changes nothing stays quiet —
    /// refresh runs on every recording edge.
    private var lastShadowed: Set<HotKeyBinding> = []

    @MainActor
    private init() {
        shortcutMatcher = ShortcutMatcher()
        handlerRegistry = ShortcutHandlerRegistry()
        fnStateMachine = FnStateMachine()
        modifierTap = ModifierTapMonitor()
        keyDownObserver = KeyDownObserver()
        carbonCenter = CarbonHotKeyCenter()

        carbonCenter.setCallback { [weak self] name, phase in
            self?.handleCarbonHotKey(name: name, phase: phase)
        }
        modifierTap.setHandler { [weak self] event in
            self?.handleModifierEvent(event) ?? false
        }
        keyDownObserver.setHandler { [weak self] in
            self?.handleKeyPressedWhileFnDown()
        }
    }

    @MainActor func start() {
        running = true
        for (name, shortcut) in shortcutMatcher.getAllShortcuts() {
            log.info("Loaded shortcut: \(name.rawValue) = \(shortcut.compactDisplayString)")
        }
        refresh()
    }

    @MainActor func stop() {
        running = false
        carbonCenter.unregisterAll()
        modifierTap.stop()
        keyDownObserver.stop()
        // Everything able to deliver a release has just gone away, so held
        // presses are completed rather than dropped. A press left marked would
        // make the tracker reject the next one as a repeat, so the shortcut
        // could never fire again — and stop() is called mid-session, not only
        // at shutdown (a permission grant restarts the manager).
        releaseStrandedPresses(keeping: [])
        fnStateMachine.reset()
        lastShadowed = []
    }

    @MainActor
    func onKeyDown(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        handlerRegistry.setKeyDownHandler(for: name, handler: handler)
    }

    @MainActor
    func onKeyUp(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        handlerRegistry.setKeyUpHandler(for: name, handler: handler)
    }

    @MainActor
    func setEnabledCheck(for name: CustomShortcutName, check: @escaping ShortcutEnabledCheck) {
        handlerRegistry.setEnabledCheck(for: name, check: check)
    }

    @MainActor
    func reloadShortcuts() {
        shortcutMatcher.reloadShortcuts()
        refresh()
    }

    /// Re-derives every registration from the current shortcuts and their
    /// enabled checks.
    ///
    /// Must be called whenever either can change. A Carbon registration
    /// swallows its chord unconditionally, so a shortcut whose feature is
    /// switched off has to be *unregistered* — leaving it registered and
    /// ignoring it at fire time would silently eat the chord instead of letting
    /// it reach the focused app.
    @MainActor
    func refresh() {
        guard running else { return }

        var requests: [HotKeyBindingPlan.Request] = []
        var modifierOnlyName: CustomShortcutName?
        let shortcuts = shortcutMatcher.getAllShortcuts()

        for name in CustomShortcutName.allCases {
            guard let shortcut = shortcuts[name] else { continue }

            switch ShortcutBackend.classify(shortcut) {
            case .modifierOnly:
                // Recorded before the enabled check: the tap must still suppress
                // the modifier press while the shortcut is merely inactive, or
                // the system action it shadows would fire intermittently.
                guard let winner = modifierOnlyName else {
                    modifierOnlyName = name
                    continue
                }
                // Only one shortcut can own the bare modifier — there is no
                // chord to tell two of them apart — and the loser fires never.
                // Silent, and indistinguishable from a broken shortcut, unless
                // it is said out loud.
                log.warning(
                    "Shortcut \(name.rawValue) is also bound to the bare modifier, which \(winner.rawValue) already owns; it will never fire"
                )

            case .carbon(let keyCode, let carbonModifiers):
                guard handlerRegistry.isEnabled(name: name) else { continue }
                requests.append(
                    .init(
                        name: name,
                        keyCode: keyCode,
                        carbonModifiers: carbonModifiers,
                        ignoresModifiers: name.ignoresModifiers))

            case .unsupported(let reason):
                log.warning(
                    "Shortcut \(name.rawValue) (\(shortcut.compactDisplayString)) cannot be registered: \(String(describing: reason))"
                )
            }
        }

        let plan = HotKeyBindingPlan.resolve(requests)
        reportShadowed(plan.shadowed)
        var liveNames = carbonCenter.sync(to: plan.bindings)

        // Which press the modifier tap is *actually* holding, as opposed to which
        // shortcut is merely bound to the bare modifier. The two backends can
        // hold the same name at different times, and only the real holder tells
        // us whether the mechanism able to release it still exists.
        let heldByModifierTap = fnStateMachine.activeFnOnlyShortcutName

        if ModifierTapPolicy.needsTap(hasModifierOnlyShortcut: modifierOnlyName != nil) {
            modifierTap.start()
            keyDownObserver.start()
            if let heldByModifierTap { liveNames.insert(heldByModifierTap) }
        } else {
            modifierTap.stop()
            keyDownObserver.stop()
            // Re-recorded as a key chord mid-hold: a fresh hot-key registration
            // under the same name makes it look live, but it cannot release a
            // press the tap took. Drop it so the drain below completes it.
            if let heldByModifierTap { liveNames.remove(heldByModifierTap) }
            fnStateMachine.reset()
        }

        releaseStrandedPresses(keeping: liveNames)
    }

    /// A registration that disappears under a held key takes its release with
    /// it, so anything still marked pressed has to be completed by hand: an
    /// abandoned press makes the tracker reject every later one as a repeat,
    /// leaving the shortcut permanently dead.
    ///
    /// Note this *performs* the key-up action, which for some shortcuts is
    /// their whole point rather than a wind-down (cancel and edit-selection both
    /// fire on release). Cancel no-ops when nothing is recording; edit-selection
    /// only checks its own setting, so a stranded release can genuinely start an
    /// edit flow. That stays acceptable only because reaching it means holding
    /// the chord across a registration teardown — practically, `stop()` at the
    /// moment Accessibility is granted.
    @MainActor
    private func releaseStrandedPresses(keeping live: Set<CustomShortcutName>) {
        pressLock.lock()
        let stranded = pressTracker.drainStranded(keeping: live)
        pressLock.unlock()

        for name in stranded {
            log.info("Registration for \(name.rawValue) went away mid-press; releasing it")
            dispatchToMain(handlerRegistry.getKeyUpHandler(for: name))
        }
    }

    @MainActor
    private func reportShadowed(_ shadowed: [HotKeyBinding]) {
        let current = Set(shadowed)
        guard current != lastShadowed else { return }
        lastShadowed = current

        for binding in shadowed {
            log.warning(
                "Shortcut \(binding.name.rawValue) keyCode=\(binding.keyCode) modifiers=\(binding.carbonModifiers) is shadowed by a higher-precedence shortcut and was not registered"
            )
        }
    }

    // MARK: - Carbon events

    @MainActor
    private func handleCarbonHotKey(name: CustomShortcutName, phase: HotKeyPhase) {
        switch phase {
        case .pressed:
            guard handlerRegistry.isEnabled(name: name) else { return }

            // Fn held while another shortcut fires means Fn is being used as a
            // modifier, not as a shortcut of its own. Retire the in-flight Fn
            // shortcut so its press cannot be left with no release to complete it.
            // The key-down observer normally gets here first; this still matters
            // when the observer has no tap (Accessibility not granted).
            if fnStateMachine.isFnKeyDown, let cancelled = fnStateMachine.markUsedAsModifier() {
                fireRelease(for: cancelled)
            }

            pressLock.lock()
            let isNewPress = pressTracker.press(name)
            pressLock.unlock()
            guard isNewPress else { return }

            dispatchToMain(handlerRegistry.getKeyDownHandler(for: name))

        case .released:
            // Deliberately not gated on the enabled check. The tracker already
            // guarantees this only fires for a press that was accepted, and
            // dropping the release because a setting flipped mid-hold would
            // strand the press — leaving the shortcut unable to fire again.
            fireRelease(for: name)
        }
    }

    /// Completes a press: clears the tracker and runs the key-up action, if the
    /// press was ever accepted.
    @discardableResult
    private func fireRelease(for name: CustomShortcutName) -> Bool {
        pressLock.lock()
        let wasPressed = pressTracker.release(name)
        pressLock.unlock()
        guard wasPressed else { return false }

        dispatchToMain(handlerRegistry.getKeyUpHandler(for: name))
        return true
    }

    /// The single way a handler reaches the main actor.
    ///
    /// Both backends go through it so that handler order is decided in one
    /// place. Running one backend's handlers synchronously while hopping for the
    /// other's guaranteed inversions — a release overtaking its own press — and
    /// this at least reduces it to the main actor's own ordering, which is FIFO
    /// per enqueue in practice though not promised by the language.
    private func dispatchToMain(_ handler: ShortcutHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler() }
    }

    // MARK: - Modifier events

    /// Runs on the modifier tap's thread. Returns true to swallow the event.
    private func handleModifierEvent(_ event: ModifierTapMonitor.FlagsEvent) -> Bool {
        guard FnKeyCode.isFnKey(event.keyCode) else { return false }

        if event.fnPressed {
            return handleModifierDown(event)
        }
        return handleModifierUp(event)
    }

    private func handleModifierDown(_ event: ModifierTapMonitor.FlagsEvent) -> Bool {
        let isNewPress = fnStateMachine.processFnKeyDown(
            captureTime: event.captureTime, hwTimestamp: event.hwTimestamp)
        guard isNewPress else { return false }

        // A press left over from a release macOS never delivered still holds the
        // tracker. Complete it first: otherwise this press is rejected as a
        // repeat and the user's tap does nothing at all.
        if let abandoned = fnStateMachine.clearActiveFnOnlyShortcut() {
            log.info("Completing abandoned \(abandoned.rawValue) press before a recovered Fn press")
            fireRelease(for: abandoned)
        }

        // From here until the release, watch for an ordinary key: that is what
        // tells Fn-as-a-shortcut apart from Fn held to reach Fn+←.
        keyDownObserver.setActive(true)

        // One lookup, reused: a match existing is exactly the condition that
        // makes the press worth swallowing at all.
        guard let match = shortcutMatcher.findFnOnlyShortcut() else {
            fnStateMachine.recordPressSwallowed(false)
            return false
        }

        guard handlerRegistry.isEnabled(name: match.name) else {
            // Still swallowed while the shortcut is bound but inactive, so the
            // system action it shadows stays consistently suppressed rather than
            // firing only some of the time.
            fnStateMachine.recordPressSwallowed(true)
            return true
        }

        fnStateMachine.setActiveFnOnlyShortcut(match.name)

        pressLock.lock()
        let accepted = pressTracker.press(match.name)
        pressLock.unlock()

        if accepted {
            dispatchToMain(handlerRegistry.getKeyDownHandler(for: match.name))
        }
        fnStateMachine.recordPressSwallowed(true)
        return true
    }

    private func handleModifierUp(_ event: ModifierTapMonitor.FlagsEvent) -> Bool {
        let result = fnStateMachine.processFnKeyUp(
            captureTime: event.captureTime, hwTimestamp: event.hwTimestamp)
        keyDownObserver.setActive(false)

        // Read before any early exit: whether the release is hidden follows from
        // whether the press was, not from what the release happens to trigger.
        let swallowRelease = fnStateMachine.consumePressSwallowed()

        if result == .fnKeyUp, let name = fnStateMachine.clearActiveFnOnlyShortcut() {
            fireRelease(for: name)
        }
        return swallowRelease
    }

    /// An ordinary key went down while the bare modifier was held.
    ///
    /// Runs on the observer tap's thread. The modifier was a modifier, so the
    /// action its press started must be retired now — otherwise Fn+← leaves a
    /// recording running with no release left to end it, since the Fn release
    /// will report itself as modifier use.
    private func handleKeyPressedWhileFnDown() {
        // One sighting settles the question for the whole hold — the state
        // machine latches it — so stop observing immediately. That also bounds
        // how long the observer can stay on if the release is ever lost: to the
        // next keystroke, rather than to the rest of the session.
        keyDownObserver.setActive(false)

        guard let retired = fnStateMachine.markUsedAsModifier() else { return }
        fireRelease(for: retired)
    }
}
