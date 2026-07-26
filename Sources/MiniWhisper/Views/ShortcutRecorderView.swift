import SwiftUI
import Carbon.HIToolbox
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ShortcutRecorder")

struct ShortcutRecorderView: View {
    @Binding var shortcut: CustomShortcut?
    @State private var isRecording = false
    @State private var context: RecorderContext?

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text("Press shortcut...")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            } else if let shortcut {
                Text(shortcut.compactDisplayString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            } else {
                Text("Not set")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        // Auto-start on appear because onTapGesture doesn't fire inside MenuBarExtra panels
        .onAppear {
            startRecording()
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - CGEventTap Recording
    // Uses CGEventTap instead of NSEvent monitors because Fn only generates
    // .flagsChanged events, which NSEvent.addLocalMonitorForEvents(.keyDown) misses entirely.
    //
    // This tap has to swallow keystrokes — capturing a chord must not also type
    // it into whatever is focused — so unlike the shortcut monitor it cannot be
    // listen-only. It is scoped as tightly as possible instead: it exists only
    // while a recorder row is on screen, waiting for a single chord.

    @MainActor
    private func startRecording() {
        let context = RecorderContext(
            onKeyDown: { keyCode, modifiers, fn in
                handleKeyDown(keyCode: keyCode, modifiers: modifiers, fnPressed: fn)
            },
            onFnOnly: {
                handleFnOnly()
            },
            onEscape: {
                stopRecording()
            }
        )

        guard RecorderContext.begin(context) else {
            log.error("Failed to create recorder event tap")
            isRecording = false
            return
        }

        self.context = context
        isRecording = true
    }

    @MainActor
    private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, fnPressed: Bool) {
        // Ignore modifier-only keys (Fn handled separately via handleFnOnly)
        let modifierKeyCodes: Set<UInt16> = [
            54, 55,  // Command
            56, 60,  // Shift
            58, 61,  // Option
            59, 62,  // Control
            57,      // Caps Lock
        ]
        guard !modifierKeyCodes.contains(keyCode) else { return }

        // Fn cannot take part in a chord: the system hot-key API has no Fn
        // modifier, and registering the chord without it would swallow the bare
        // key everywhere — binding Fn+W would stop W reaching any app. Keep
        // listening instead of storing a binding that could never fire.
        guard !fnPressed else {
            log.info("Ignoring Fn chord: Fn is only bindable on its own")
            return
        }

        let newShortcut = CustomShortcut(
            keyCode: keyCode,
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift)
        )

        shortcut = newShortcut
        stopRecording()
    }

    @MainActor
    private func handleFnOnly() {
        let newShortcut = CustomShortcut(
            keyCode: 63,
            command: false,
            option: false,
            control: false,
            shift: false,
            fn: false  // fn flag is for "Fn as modifier", not when Fn IS the key
        )

        shortcut = newShortcut
        stopRecording()
    }

    @MainActor
    private func stopRecording() {
        isRecording = false
        if let context {
            RecorderContext.end(context)
        }
        context = nil
    }
}

/// Mutable state for the recorder tap's C callback, which reaches it through a
/// refcon that does not retain — hence the process-wide reference below, which
/// is what keeps it alive.
///
/// Invariant: this type is confined to the main run loop, and that confinement
/// is its only synchronization. The tap's run-loop source is added to the main
/// run loop, so the callback, the re-enable timers and every field access all
/// happen on the main thread. Servicing the tap on another thread would turn
/// each field here into a data race, and the process-wide reference into a
/// use-after-free the moment a row disappears mid-event.
///
/// The confinement costs nothing that matters: this tap is created by an
/// explicit user action, lives for the seconds it takes to press one chord, and
/// is then gone.
@MainActor
final class RecorderContext {
    private static var current: RecorderContext?

    private let onKeyDown: (UInt16, NSEvent.ModifierFlags, Bool) -> Void
    private let onFnOnly: () -> Void
    private let onEscape: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnKeyDown = false
    private var otherKeyPressedDuringFn = false
    private var fnPressTime: CFAbsoluteTime?
    /// Longer than this and the Fn press is a hold, not a binding gesture.
    private let maxTapDuration: TimeInterval = 0.5
    private let timeoutReenableDelays: [TimeInterval] = [0.25, 0.5, 1.0]
    private var timeoutReenableAttempts = 0
    private var timeoutReenableScheduled = false

    init(
        onKeyDown: @escaping (UInt16, NSEvent.ModifierFlags, Bool) -> Void,
        onFnOnly: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) {
        self.onKeyDown = onKeyDown
        self.onFnOnly = onFnOnly
        self.onEscape = onEscape
    }

    // MARK: - Lifecycle

    /// Makes `context` the live recorder and starts its tap.
    ///
    /// At most one recorder may be live: the callback finds its state through a
    /// single process-wide reference, so a second row starting would strand the
    /// first row's tap with nothing able to reach or disable it — a tap that
    /// swallows keystrokes with no way left to stop it.
    static func begin(_ context: RecorderContext) -> Bool {
        if let previous = current {
            previous.teardown()
            current = nil
            // Let the superseded row leave its recording state; it can no longer
            // receive anything.
            previous.onEscape()
        }

        guard context.createTap() else { return false }
        current = context
        return true
    }

    static func end(_ context: RecorderContext) {
        context.teardown()
        if current === context { current = nil }
    }

    private func createTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: recorderTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        log.info("Recorder event tap created")
        return true
    }

    private func teardown() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        timeoutReenableScheduled = false
    }

    // MARK: - Event handling

    /// Returns whether the event was consumed and must not reach anything else.
    fileprivate func process(_ event: RecorderEvent) -> Bool {
        let type = CGEventType(rawValue: event.typeRawValue)

        if type == .tapDisabledByUserInput {
            reenableImmediately()
            return false
        }

        if type == .tapDisabledByTimeout {
            reenableAfterTimeout()
            return false
        }

        resetTimeoutBackoff()

        let keyCode = event.keyCode
        let flags = CGEventFlags(rawValue: event.flagsRawValue)

        switch type {
        case .flagsChanged:
            // Only the modifier change that completed a capture is swallowed;
            // every other one has to pass through, or modifier state elsewhere
            // in the system goes stale.
            return handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            // Always consumed: capturing a chord must not also type it into
            // whatever is focused behind the settings UI.
            handleKeyDown(keyCode: keyCode, flags: flags)
            return true
        default:
            return false
        }
    }

    /// Returns whether the event was consumed.
    private func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let fnPressed = flags.contains(.maskSecondaryFn)
        let wasFnDown = fnKeyDown
        fnKeyDown = fnPressed

        // Other modifiers pass straight through. Swallowing them would leave
        // every other app believing a modifier is still held after capture.
        guard FnKeyCode.isFnKey(keyCode) else { return false }

        // Both edges of Fn are consumed, not just the one that completes a
        // capture. Letting the press through while eating the release is what
        // makes binding Fn start a recording it then has no release left to
        // stop: the shortcut monitor's own tap sits behind this one and would
        // see an Fn press that never ends.
        if fnPressed && !wasFnDown {
            fnPressTime = CFAbsoluteTimeGetCurrent()
            otherKeyPressedDuringFn = false
            return true
        }

        guard !fnPressed && wasFnDown else { return true }

        let wasTap: Bool
        if let fnPressTime {
            wasTap = (CFAbsoluteTimeGetCurrent() - fnPressTime) < maxTapDuration
        } else {
            wasTap = false
        }
        fnPressTime = nil

        guard wasTap && !otherKeyPressedDuringFn else { return true }

        deliver { $0.onFnOnly() }
        return true
    }

    private func handleKeyDown(keyCode: UInt16, flags: CGEventFlags) {
        if fnKeyDown {
            otherKeyPressedDuringFn = true
        }

        if keyCode == UInt16(kVK_Escape) {
            deliver { $0.onEscape() }
            return
        }

        let modifiers = flags.modifierFlags
        let heldFn = FunctionKeyGroup.indicatesHeldFn(
            keyCode: keyCode,
            secondaryFnFlagSet: flags.contains(.maskSecondaryFn),
            fnKeyIsDown: fnKeyDown
        )

        deliver { $0.onKeyDown(keyCode, modifiers, heldFn) }
    }

    /// Runs a capture callback after this event has been returned.
    ///
    /// Deliberately deferred: every one of them ends the recording, which
    /// invalidates the very tap whose callback is running.
    private func deliver(_ body: @escaping (RecorderContext) -> Void) {
        Task { @MainActor [self] in body(self) }
    }

    // MARK: - Re-enable handling

    private func reenableImmediately() {
        timeoutReenableAttempts = 0
        timeoutReenableScheduled = false
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func reenableAfterTimeout() {
        guard !timeoutReenableScheduled else { return }
        guard timeoutReenableAttempts < timeoutReenableDelays.count else {
            log.error("Recorder event tap repeatedly disabled by timeout; aborting shortcut capture")
            deliver { $0.onEscape() }
            return
        }

        let delay = timeoutReenableDelays[timeoutReenableAttempts]
        timeoutReenableAttempts += 1
        timeoutReenableScheduled = true
        log.warning("Recorder event tap disabled by timeout; scheduling re-enable")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Dispatched onto the main queue, which is where this type lives, so
            // the isolation being assumed is the one the dispatch guarantees.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timeoutReenableScheduled = false
                guard let eventTap = self.eventTap else { return }
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        }
    }

    private func resetTimeoutBackoff() {
        timeoutReenableAttempts = 0
        timeoutReenableScheduled = false
    }
}

/// The minimum copied out of a `CGEvent`, which cannot itself be handed to the
/// main actor and whose pointer is only valid for the length of the callback.
struct RecorderEvent: Sendable {
    let typeRawValue: UInt32
    let keyCode: UInt16
    let flagsRawValue: UInt64
}

/// The tap's source lives on the main run loop, so this runs on the main
/// thread — which is what makes `RecorderContext`'s unsynchronized state safe to
/// touch from here.
private let recorderTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<RecorderContext>.fromOpaque(refcon).takeUnretainedValue()

    let facts = RecorderEvent(
        typeRawValue: type.rawValue,
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        flagsRawValue: event.flags.rawValue
    )

    let consumed = MainActor.assumeIsolated { context.process(facts) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
