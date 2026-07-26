import Carbon.HIToolbox
import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "CarbonHotKey")

/// Which edge of a hot key fired. Both edges are delivered because some
/// shortcuts act on release rather than press — edit-selection waits for the
/// user's modifiers to come up before it synthesizes a copy.
enum HotKeyPhase: Sendable {
    case pressed
    case released
}

/// Registers system-wide hot keys through Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys are matched by the window server and delivered to this
/// process as ordinary application events, so this app is never part of the
/// keystroke-delivery path: no keystroke anywhere waits on this code, and a
/// hang here cannot slow input for other apps. The registration also swallows
/// the chord for us, so the focused app never sees a shortcut we handle.
///
/// The trade-off is that a registration is unconditional — Carbon has no notion
/// of "handle this only when a feature is on". Anything that gates a shortcut
/// must therefore add or remove the registration itself; see `sync(to:)`.
@MainActor
final class CarbonHotKeyCenter {
    typealias Callback = @MainActor (CustomShortcutName, HotKeyPhase) -> Void

    /// Tags this process's hot keys inside the shared Carbon dispatcher, which
    /// carries every registration in the session.
    private static let signature: OSType = 0x4D57_484B  // 'MWHK'

    private var callback: Callback?
    private var eventHandler: EventHandlerRef?
    private var handlerGate = HotKeyHandlerGate()
    private var registrations: [UInt32: (binding: HotKeyBinding, ref: EventHotKeyRef)] = [:]
    /// Registrations the OS refused to release. Kept so they can be retried:
    /// see `unregister(_:)`.
    private var failedUnregistrations: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    func setCallback(_ callback: @escaping Callback) {
        self.callback = callback
    }

    /// Makes the live registrations match `desired`, adding and removing only
    /// the difference so unrelated shortcuts keep working across a refresh.
    ///
    /// `desired` is ordered, and registration follows that order: the OS awards
    /// a contested chord to whoever asks first, so the caller's precedence is
    /// only honoured if this does not reorder.
    ///
    /// Returns the shortcuts that ended up with at least one live registration,
    /// which is not always all of them — the system keeps chords it already owns.
    @discardableResult
    func sync(to desired: [HotKeyBinding]) -> Set<CustomShortcutName> {
        let desiredSet = Set(desired)
        for (id, entry) in registrations where !desiredSet.contains(entry.binding) {
            unregister(entry.ref)
            registrations[id] = nil
        }
        retryFailedUnregistrations()

        let current = Set(registrations.values.map(\.binding))
        for binding in desired where !current.contains(binding) {
            register(binding)
        }

        return Set(registrations.values.map(\.binding.name))
    }

    func unregisterAll() {
        for entry in registrations.values {
            unregister(entry.ref)
        }
        registrations.removeAll()
        retryFailedUnregistrations()
    }

    private func register(_ binding: HotKeyBinding) {
        // Fail closed. A registration swallows its chord system-wide whether or
        // not anything is listening, so registering without a live dispatcher
        // handler would make the chord dead in every app with no way to notice.
        guard handlerGate.ensureInstalled(installEventHandler) else {
            log.error(
                "Refusing to register \(binding.name.rawValue): no hot-key handler is installed"
            )
            return
        }

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // Expected for combinations the system already owns (Force Quit and
            // friends); those simply stay with the system.
            log.info(
                "Hot key not registered: \(binding.name.rawValue) keyCode=\(binding.keyCode) modifiers=\(binding.carbonModifiers) status=\(status)"
            )
            return
        }

        registrations[id] = (binding, ref)
    }

    /// Releases a hot key, keeping the reference for a later attempt if the OS
    /// refuses.
    ///
    /// Dropping a reference that failed to unregister strands the registration
    /// for the lifetime of the process: the chord stays swallowed system-wide
    /// and nothing is left that could ever release it.
    private func unregister(_ ref: EventHotKeyRef) {
        let status = UnregisterEventHotKey(ref)
        guard status != noErr else { return }
        log.error("UnregisterEventHotKey failed (status \(status)); retaining for retry")
        failedUnregistrations.append(ref)
    }

    private func retryFailedUnregistrations() {
        guard !failedUnregistrations.isEmpty else { return }
        let remaining = failedUnregistrations.filter { UnregisterEventHotKey($0) != noErr }
        if remaining.count != failedUnregistrations.count {
            log.info("Released \(self.failedUnregistrations.count - remaining.count) retried hot key(s)")
        }
        failedUnregistrations = remaining
    }

    private func installEventHandler() -> Bool {
        guard let dispatcher = GetEventDispatcherTarget() else {
            log.error("No Carbon event dispatcher available")
            return false
        }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            dispatcher,
            carbonHotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        guard status == noErr, let handler else {
            log.error("InstallEventHandler failed: \(status)")
            return false
        }
        eventHandler = handler
        return true
    }

    fileprivate func handle(id: UInt32, signature: OSType, phase: HotKeyPhase) -> OSStatus {
        guard signature == Self.signature, let entry = registrations[id] else {
            return OSStatus(eventNotHandledErr)
        }
        callback?(entry.binding.name, phase)
        return noErr
    }
}

/// Enforces "no chord may be registered without a live handler", and installs
/// that handler at most once.
///
/// Split out from the registration path because the failure it guards is silent
/// and permanent: a hot key whose events nothing receives still swallows its
/// chord in every app, so the only safe response to a failed install is to
/// register nothing at all and try installing again later.
struct HotKeyHandlerGate {
    private(set) var isInstalled = false

    /// Runs `install` only while no handler is live, and reports whether one is.
    mutating func ensureInstalled(_ install: () -> Bool) -> Bool {
        if isInstalled { return true }
        isInstalled = install()
        return isInstalled
    }
}

/// Carbon dispatches these from the main event loop, so main-actor isolation
/// holds even though the C signature cannot express it.
///
/// Everything needed is read out of the `EventRef` here, before the hop: the
/// event pointer is only valid for the duration of this call and carries no
/// isolation guarantees of its own.
private func carbonHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    let phase: HotKeyPhase
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed: phase = .pressed
    case kEventHotKeyReleased: phase = .released
    default: return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    let signature = hotKeyID.signature
    let center = Unmanaged<CarbonHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()

    return MainActor.assumeIsolated { center.handle(id: id, signature: signature, phase: phase) }
}
