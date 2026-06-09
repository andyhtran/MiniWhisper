import Foundation
import CoreGraphics
import AppKit
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ShortcutMonitor")

final class CustomShortcutMonitor: @unchecked Sendable {
    typealias ShortcutHandler = @Sendable @MainActor () -> Void
    typealias ShortcutEnabledCheck = @Sendable () -> Bool

    @MainActor static let shared = CustomShortcutMonitor()

    private let eventTapManager: EventTapManager
    private let shortcutMatcher: ShortcutMatcher
    private let handlerRegistry: ShortcutHandlerRegistry
    private let fnStateMachine: FnStateMachine
    private let doubleTapDetector: DoubleTapDetector

    private var activeShortcuts: Set<CustomShortcutName> = []
    private let activeShortcutsLock = NSLock()

    @MainActor
    private init() {
        self.shortcutMatcher = ShortcutMatcher()
        self.handlerRegistry = ShortcutHandlerRegistry()
        self.fnStateMachine = FnStateMachine()
        self.doubleTapDetector = DoubleTapDetector()
        self.eventTapManager = EventTapManager()

        eventTapManager.setEventCallback { [unowned self] type, event in
            self.processEvent(type: type, event: event)
        }
    }

    @MainActor func start() {
        let shortcuts = shortcutMatcher.getAllShortcuts()
        for (name, shortcut) in shortcuts {
            log.info("Loaded shortcut: \(name.rawValue) = keyCode=\(shortcut.keyCode) opt=\(shortcut.option) cmd=\(shortcut.command) display=\(shortcut.compactDisplayString)")
        }
        let hasToggleHandler = handlerRegistry.getKeyDownHandler(for: .toggleRecording) != nil
        log.info("Toggle recording handler registered: \(hasToggleHandler)")
        eventTapManager.start()
    }
    @MainActor func stop() {
        eventTapManager.stop()
        fnStateMachine.reset()
        doubleTapDetector.reset()
        activeShortcutsLock.lock()
        activeShortcuts.removeAll()
        activeShortcutsLock.unlock()
    }

    @MainActor
    func onKeyDown(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        handlerRegistry.setKeyDownHandler(for: name, handler: handler)
    }

    @MainActor
    func onKeyUp(for name: CustomShortcutName, handler: @escaping ShortcutHandler) {
        handlerRegistry.setKeyUpHandler(for: name, handler: handler)
    }

    func setEnabledCheck(for name: CustomShortcutName, check: @escaping ShortcutEnabledCheck) {
        handlerRegistry.setEnabledCheck(for: name, check: check)
    }

    /// For a double-tap shortcut, also fire on a single tap while `check` is
    /// true (toggle-recording uses this for "tap again to stop").
    func setSingleTapCheck(for name: CustomShortcutName, check: @escaping ShortcutEnabledCheck) {
        handlerRegistry.setSingleTapCheck(for: name, check: check)
    }

    func reloadShortcuts() {
        shortcutMatcher.reloadShortcuts()
    }

    // MARK: - Event Processing

    private func processEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            return handleFlagsChanged(event: event, keyCode: keyCode)
        }

        let flags = event.flags
        let modifiers = flags.modifierFlags
        let fnPressed = fnStateMachine.isFnKeyDown || flags.contains(.maskSecondaryFn)

        if type == .keyDown {
            let result = handleKeyDown(keyCode: keyCode, modifiers: modifiers, fnPressed: fnPressed)
            if result {
                log.info("Matched keyDown: keyCode=\(keyCode) cmd=\(modifiers.contains(.command)) opt=\(modifiers.contains(.option))")
            }
            return result
        } else if type == .keyUp {
            return handleKeyUp(keyCode: keyCode)
        }

        return false
    }

    private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, fnPressed: Bool) -> Bool {
        // A real key went down: any modifier held right now is being used in a
        // combo (not tapped), and this breaks a pending double-tap chain.
        doubleTapDetector.noteOtherKeyDown()

        // If Fn is held and a non-Fn key goes down, mark as modifier combo
        if fnPressed && !FnKeyCode.isFnKey(keyCode) {
            if let cancelledName = fnStateMachine.markUsedAsModifier() {
                if let handler = handlerRegistry.getKeyUpHandler(for: cancelledName) {
                    Task { @MainActor in handler() }
                }
            }
        }

        // cancelRecording: modifier-insensitive when enabled.
        // Consume keyDown so other apps don't see it; actual cancel fires on keyUp.
        if let cancelShortcut = shortcutMatcher.getAllShortcuts()[.cancelRecording],
           cancelShortcut.keyCode == keyCode,
           handlerRegistry.isEnabled(name: .cancelRecording) {
            return true
        }

        guard let match = shortcutMatcher.findMatch(keyCode: keyCode, modifiers: modifiers, fnPressed: fnPressed) else {
            return false
        }

        if !handlerRegistry.isEnabled(name: match.name) { return false }

        activeShortcutsLock.lock()
        let alreadyActive = activeShortcuts.contains(match.name)
        if !alreadyActive { activeShortcuts.insert(match.name) }
        activeShortcutsLock.unlock()

        guard !alreadyActive else { return true }

        if let handler = handlerRegistry.getKeyDownHandler(for: match.name) {
            Task { @MainActor in handler() }
        }

        return true
    }

    private func handleKeyUp(keyCode: UInt16) -> Bool {
        // cancelRecording: stateless and modifier-insensitive on keyUp.
        // Only check keyCode match, ignoring modifiers.
        if let cancelShortcut = shortcutMatcher.getAllShortcuts()[.cancelRecording],
           cancelShortcut.keyCode == keyCode {
            if handlerRegistry.isEnabled(name: .cancelRecording),
               let handler = handlerRegistry.getKeyUpHandler(for: .cancelRecording) {
                activeShortcutsLock.lock()
                activeShortcuts.remove(.cancelRecording)
                activeShortcutsLock.unlock()

                Task { @MainActor in handler() }
                return true
            }
            return false
        }

        guard let match = shortcutMatcher.findByKeyCode(keyCode) else { return false }

        activeShortcutsLock.lock()
        let wasActive = activeShortcuts.remove(match.name) != nil
        activeShortcutsLock.unlock()

        if !handlerRegistry.isEnabled(name: match.name) { return false }
        guard wasActive else { return false }

        if let handler = handlerRegistry.getKeyUpHandler(for: match.name) {
            Task { @MainActor in handler() }
        }

        return true
    }

    private func handleFlagsChanged(event: CGEvent, keyCode: UInt16) -> Bool {
        let captureTime = CFAbsoluteTimeGetCurrent()
        let hwTimestamp = event.timestamp
        let flags = event.flags
        let fnPressed = flags.contains(.maskSecondaryFn)
        let isFnKey = FnKeyCode.isFnKey(keyCode)

        if !isFnKey {
            // Non-Fn modifier (Option/Cmd/Ctrl/Shift): feed the double-tap detector.
            if ModifierKeyCode.isModifierKey(keyCode) {
                return handleModifierTap(keyCode: keyCode, flags: flags, time: captureTime)
            }
            return false
        }

        if fnPressed {
            let isNewPress = fnStateMachine.processFnKeyDown(captureTime: captureTime, hwTimestamp: hwTimestamp)
            guard isNewPress else { return false }

            if let match = shortcutMatcher.findFnOnlyShortcut(),
               handlerRegistry.isEnabled(name: match.name) {
                fnStateMachine.setActiveFnOnlyShortcut(match.name)
                if let handler = handlerRegistry.getKeyDownHandler(for: match.name) {
                    Task { @MainActor in handler() }
                }
                return true
            }
            return shortcutMatcher.hasFnOnlyShortcut()
        } else {
            let result = fnStateMachine.processFnKeyUp(captureTime: captureTime, hwTimestamp: hwTimestamp)
            switch result {
            case .fnKeyUp:
                if let name = fnStateMachine.clearActiveFnOnlyShortcut(),
                   let handler = handlerRegistry.getKeyUpHandler(for: name) {
                    Task { @MainActor in handler() }
                    return true
                }
                return false
            case .usedAsModifier:
                return false
            default:
                return false
            }
        }
    }

    /// Double-tap-of-a-modifier handling. We *observe* the modifier's
    /// flagsChanged events and never consume them, so the key keeps working as
    /// a normal modifier for typing — the action fires only as a side effect of
    /// a detected tap / double-tap.
    private func handleModifierTap(keyCode: UInt16, flags: CGEventFlags, time: CFAbsoluteTime) -> Bool {
        // Only do work if a double-tap shortcut is actually bound to this key.
        guard let match = shortcutMatcher.findDoubleTapShortcut(forKeyCode: keyCode) else {
            return false
        }

        if ModifierKeyCode.flagPresent(forKeyCode: keyCode, in: flags) {
            doubleTapDetector.modifierDown(keyCode: keyCode, time: time)
            return false
        }

        let result = doubleTapDetector.modifierUp(keyCode: keyCode, time: time)
        guard handlerRegistry.isEnabled(name: match.name) else { return false }

        switch result {
        case .doubleTap:
            fireDoubleTapAction(match.name)
        case .tap:
            // A single tap only acts when explicitly enabled (toggle-recording
            // opts in so a tap stops an in-progress recording). Clear the chain
            // so a quick follow-up tap isn't read as a double-tap.
            if handlerRegistry.singleTapEnabled(name: match.name) {
                fireDoubleTapAction(match.name)
                doubleTapDetector.clearTapChain()
            }
        case .none:
            break
        }
        return false
    }

    private func fireDoubleTapAction(_ name: CustomShortcutName) {
        if let handler = handlerRegistry.getKeyDownHandler(for: name) {
            Task { @MainActor in handler() }
        }
    }
}
