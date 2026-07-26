import ApplicationServices
import CoreGraphics
import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ModifierTap")

/// Watches bare-modifier presses for shortcuts Carbon cannot express.
///
/// Scope is deliberately as small as it can be: the tap only exists while a
/// modifier-only shortcut is bound, and its mask is exactly `.flagsChanged`, so
/// ordinary typing never reaches this process. Key chords are handled by Carbon
/// and need no tap at all.
final class ModifierTapMonitor: @unchecked Sendable {
    /// The minimum copied out of a `CGEvent` so the callback can hand off and
    /// return immediately rather than keeping the event alive.
    struct FlagsEvent: Sendable {
        let keyCode: UInt16
        let fnPressed: Bool
        let hwTimestamp: UInt64
        let captureTime: CFAbsoluteTime
    }

    /// Runs on the tap thread. Returns true to hide the event from the rest of
    /// the system.
    ///
    /// Warning: the window server holds every keystroke in the session until
    /// this returns. It must stay allocation-light and must never block on
    /// another thread — in particular never `DispatchQueue.main.sync`.
    typealias Handler = @Sendable (FlagsEvent) -> Bool

    private let lock = NSLock()
    private var handler: Handler?
    private var tap: EventTapHandle?
    private var runLoop: EventTapRunLoop?
    private var shouldRun = false
    /// Written from the tap thread, read by the watchdog; both under `lock`.
    private var lastEventTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var starvedRebuilds = 0

    private var watchdogTimer: Timer?
    private var retryTimer: Timer?

    private static let watchdogInterval: TimeInterval = 30
    /// Only the burst of fast retries. Creation keeps being retried at watchdog
    /// cadence afterwards, because the usual reason it fails is an Accessibility
    /// grant that has not been given yet and may be given minutes later.
    private static let maxCreateAttempts = 10

    /// Whether a bare modifier press must be hidden from the rest of the
    /// system, which is the only thing that justifies a filter tap here.
    ///
    /// It is load-bearing for any bare-modifier shortcut: the press must not
    /// also reach whatever the system's "Press 🌐 to…" setting is bound to, or
    /// every trigger would additionally switch input source or open the emoji
    /// picker.
    private let suppressesModifierPress: Bool

    init(suppressesModifierPress: Bool = true) {
        self.suppressesModifierPress = suppressesModifierPress
    }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    @MainActor
    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        // Started here rather than at each tap creation: a rebuild must not
        // reset the activity clock, or a tap that starves again immediately
        // would look freshly healthy and the rebuild counter could never read
        // higher than one.
        lock.lock()
        lastEventTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        createTap()
        startWatchdog()
    }

    @MainActor
    func stop() {
        shouldRun = false
        retryTimer?.invalidate()
        retryTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        teardownTap()
    }

    // MARK: - Tap lifecycle

    @MainActor
    private func createTap(attempt: Int = 0) {
        guard shouldRun else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let options = ModifierTapPolicy.tapOption(
            suppressesModifierPress: suppressesModifierPress)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: ModifierTapPolicy.eventMask,
                callback: modifierTapCallback,
                userInfo: refcon
            )
        else {
            log.error("Modifier tap creation failed (attempt \(attempt + 1)/\(Self.maxCreateAttempts))")
            guard attempt + 1 < Self.maxCreateAttempts else {
                log.error(
                    "Modifier tap creation still failing; falling back to watchdog-paced retries. Check Accessibility permission in System Settings."
                )
                return
            }
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    self?.createTap(attempt: attempt + 1)
                }
            }
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil

        let handle = EventTapHandle(port: tap)
        let loop = EventTapRunLoop()
        lock.lock()
        self.tap = handle
        self.runLoop = loop
        lock.unlock()

        loop.start(tap: handle, name: "app.hotkeys.modifier-tap")
        log.info("Modifier tap created (filter: \(self.suppressesModifierPress))")
    }

    @MainActor
    private func teardownTap() {
        lock.lock()
        let tap = self.tap
        let loop = self.runLoop
        self.tap = nil
        self.runLoop = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFMachPortInvalidate(tap.port)
        }
        loop?.stop()
    }

    @MainActor
    private func recreate() {
        guard shouldRun else { return }
        teardownTap()
        createTap()
    }

    @MainActor
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        // The timer retains its block, and the block is what would otherwise
        // retain this monitor for as long as the timer lives.
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkTapHealth()
            }
        }
    }

    /// The `tapDisabledBy*` callbacks only arrive while the tap is still being
    /// serviced, so a tap that dies quietly is only visible by asking.
    @MainActor
    private func checkTapHealth() {
        guard shouldRun else { return }
        lock.lock()
        let handle = self.tap
        let silent = CFAbsoluteTimeGetCurrent() - lastEventTime
        lock.unlock()

        guard let tap = handle?.port else {
            // Creation's own retry budget is short, and the reason it usually
            // fails — no Accessibility grant yet — can take arbitrarily long to
            // resolve. Without a retry here nothing would rebuild the tap short
            // of restarting the app.
            log.info("Modifier tap missing while it should be running; retrying creation")
            createTap()
            return
        }

        if !CGEvent.tapIsEnabled(tap: tap) {
            log.warning("Watchdog found modifier tap disabled; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.error("Re-enable did not stick; recreating modifier tap")
                recreate()
            }
            return
        }

        // Reaching here means the tap claims to be enabled, which a starved tap
        // also does — hence the second, external opinion below.
        let latencyUs = reportedTapLatencyUs()
        if TapStarvationPolicy.isStarved(silentFor: silent, reportedLatencyUs: latencyUs) {
            starvedRebuilds += 1
            let latencySeconds = Int((latencyUs ?? 0) / 1_000_000)
            log.error(
                "Tap starved — enabled but WindowServer queue latency \(latencySeconds)s; recreating (rebuild #\(self.starvedRebuilds) since last healthy tick)"
            )
            recreate()
            return
        }
        starvedRebuilds = 0
    }

    /// The window server's queue latency for this tap, matched by tapping pid
    /// plus event mask — the process can host other taps (the shortcut recorder
    /// and the Fn companion observer both use different masks), and only this
    /// one's health is being judged.
    ///
    /// The value grows in lockstep with wall clock while an event sits
    /// undelivered, which is what separates a starved tap from an idle one.
    private func reportedTapLatencyUs() -> Float? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return nil }

        let pid = getpid()
        return taps.prefix(Int(count))
            .filter { $0.tappingProcess == pid && $0.eventsOfInterest == ModifierTapPolicy.eventMask }
            .map(\.avgUsecLatency)
            .max()
    }

    // MARK: - Callback entry points

    fileprivate func deliver(_ event: FlagsEvent) -> Bool {
        lock.lock()
        let handler = self.handler
        // Proof the tap is still being serviced. Its absence is what the
        // watchdog's starvation check keys off.
        lastEventTime = event.captureTime
        lock.unlock()
        return handler?(event) ?? false
    }

    fileprivate func handleTapDisabled() {
        lock.lock()
        let handle = self.tap
        lastEventTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        guard let tap = handle?.port else { return }

        log.warning("Modifier tap disabled by system; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            log.error("Re-enable did not stick; scheduling modifier tap recreate")
            Task { @MainActor [weak self] in
                self?.recreate()
            }
            return
        }
    }
}

private let modifierTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

    let facts = ModifierTapMonitor.FlagsEvent(
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        fnPressed: event.flags.contains(.maskSecondaryFn),
        hwTimestamp: event.timestamp,
        captureTime: CFAbsoluteTimeGetCurrent()
    )

    return monitor.deliver(facts) ? nil : Unmanaged.passUnretained(event)
}
