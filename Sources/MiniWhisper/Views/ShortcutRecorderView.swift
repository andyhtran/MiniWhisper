import SwiftUI
import Carbon.HIToolbox
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ShortcutRecorder")

struct ShortcutRecorderView: View {
    @Binding var shortcut: CustomShortcut?
    @State private var isRecording = false
    @State private var eventTap: CFMachPort?
    @State private var runLoopSource: CFRunLoopSource?

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

    private func startRecording() {
        isRecording = true

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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

        RecorderContext.current = context
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let ctx = Unmanaged<RecorderContext>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByUserInput {
                    ctx.reenableImmediately()
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByTimeout {
                    ctx.reenableAfterTimeout()
                    return Unmanaged.passUnretained(event)
                }

                ctx.resetTimeoutBackoff()

                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                if type == .flagsChanged {
                    let fnPressed = flags.contains(.maskSecondaryFn)
                    let wasFnDown = ctx.fnKeyDown
                    ctx.fnKeyDown = fnPressed

                    let isFnKey = FnKeyCode.isFnKey(keyCode)
                    if isFnKey {
                        if fnPressed && !wasFnDown {
                            ctx.fnPressTime = CFAbsoluteTimeGetCurrent()
                            ctx.otherKeyPressedDuringFn = false
                        } else if !fnPressed && wasFnDown {
                            let wasTap: Bool
                            if let pressTime = ctx.fnPressTime {
                                wasTap = (CFAbsoluteTimeGetCurrent() - pressTime) < ctx.maxTapDuration
                            } else {
                                wasTap = false
                            }
                            ctx.fnPressTime = nil

                            if wasTap && !ctx.otherKeyPressedDuringFn {
                                DispatchQueue.main.async { ctx.onFnOnly() }
                                return nil
                            }
                        }
                    }

                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    if ctx.fnKeyDown {
                        ctx.otherKeyPressedDuringFn = true
                    }

                    if keyCode == UInt16(kVK_Escape) {
                        DispatchQueue.main.async { ctx.onEscape() }
                        return nil
                    }

                    let modifiers = flags.modifierFlags
                    let fnPressed = flags.contains(.maskSecondaryFn) || ctx.fnKeyDown

                    DispatchQueue.main.async { ctx.onKeyDown(keyCode, modifiers, fnPressed) }
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        guard let eventTap else {
            log.error("Failed to create recorder event tap")
            isRecording = false
            RecorderContext.current = nil
            return
        }
        context.eventTap = eventTap
        log.info("Recorder event tap created")

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

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

        let newShortcut = CustomShortcut(
            keyCode: keyCode,
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift),
            fn: fnPressed
        )

        shortcut = newShortcut
        stopRecording()
    }

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

    private func stopRecording() {
        isRecording = false

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        RecorderContext.current?.eventTap = nil
        eventTap = nil
        runLoopSource = nil
        RecorderContext.current = nil
    }
}

/// Mutable state for the CGEventTap C callback. Stored in `current` to prevent
/// deallocation since the tap's refcon uses passUnretained.
final class RecorderContext: @unchecked Sendable {
    nonisolated(unsafe) static var current: RecorderContext?

    let onKeyDown: (UInt16, NSEvent.ModifierFlags, Bool) -> Void
    let onFnOnly: () -> Void
    let onEscape: () -> Void

    var eventTap: CFMachPort?
    var fnKeyDown: Bool = false
    var otherKeyPressedDuringFn: Bool = false
    var fnPressTime: CFAbsoluteTime?
    let maxTapDuration: TimeInterval = 0.5
    private let timeoutReenableDelays: [TimeInterval] = [0.25, 0.5, 1.0]
    private var timeoutReenableAttempts = 0
    private var timeoutReenableScheduled = false

    func reenableImmediately() {
        timeoutReenableAttempts = 0
        timeoutReenableScheduled = false
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func reenableAfterTimeout() {
        guard !timeoutReenableScheduled else { return }
        guard timeoutReenableAttempts < timeoutReenableDelays.count else {
            log.error("Recorder event tap repeatedly disabled by timeout; aborting shortcut capture")
            DispatchQueue.main.async { [weak self] in
                self?.onEscape()
            }
            return
        }

        let delay = timeoutReenableDelays[timeoutReenableAttempts]
        timeoutReenableAttempts += 1
        timeoutReenableScheduled = true
        log.warning("Recorder event tap disabled by timeout; scheduling re-enable")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.timeoutReenableScheduled = false
            guard let eventTap = self.eventTap else { return }
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func resetTimeoutBackoff() {
        timeoutReenableAttempts = 0
        timeoutReenableScheduled = false
    }

    init(
        onKeyDown: @escaping (UInt16, NSEvent.ModifierFlags, Bool) -> Void,
        onFnOnly: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) {
        self.onKeyDown = onKeyDown
        self.onFnOnly = onFnOnly
        self.onEscape = onEscape
    }
}
