import CoreGraphics
import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "KeyDownObserver")

/// Reports that some ordinary key went down, for the span of a modifier hold.
///
/// It exists for one question: was the modifier a shortcut, or was the user
/// holding it to reach Fn+←? Nothing else can answer it — a chord that combines
/// a held modifier with an ordinary key is not something the hot-key API can
/// match, so the key press has to be seen directly.
///
/// Two properties keep that cheap. The tap is listen-only, so the window server
/// never waits on it and it cannot delay a keystroke for anyone. And it is
/// enabled only while the modifier is actually down, so outside those brief
/// windows this process observes no typing at all.
///
/// Those same two properties are why this has no starvation watchdog, unlike
/// `ModifierTapMonitor`. A listen-only tap cannot stall the system, and one that
/// is disabled almost all the time gives the latency heuristic nothing to
/// measure — it would read idle as starved. The absence is deliberate.
final class KeyDownObserver: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    /// Ordinary keys only. Modifier presses arrive as `.flagsChanged` and are
    /// none of this observer's business.
    static let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

    private let lock = NSLock()
    private var handler: Handler?
    private var tap: EventTapHandle?
    private var runLoop: EventTapRunLoop?
    private var shouldRun = false
    /// Whether the modifier is currently held. Toggled from the modifier tap's
    /// thread, read in this tap's callback.
    private var active = false

    private var retryTimer: Timer?
    private static let retryInterval: TimeInterval = 30

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    @MainActor
    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        createTap()
    }

    @MainActor
    func stop() {
        shouldRun = false
        retryTimer?.invalidate()
        retryTimer = nil

        lock.lock()
        let handle = tap
        let loop = runLoop
        tap = nil
        runLoop = nil
        active = false
        lock.unlock()

        if let handle {
            CGEvent.tapEnable(tap: handle.port, enable: false)
            CFMachPortInvalidate(handle.port)
        }
        loop?.stop()
    }

    /// Called on each modifier transition, from the modifier tap's thread.
    ///
    /// Enabling here rather than hopping to another thread is deliberate: the
    /// very next event may be the key press this observer exists to catch, and a
    /// hop would let it slip through before the tap was listening.
    ///
    /// `CGEvent.tapEnable` is a round trip to the window server, so this is the
    /// one place the modifier tap's callback blocks on something external. It is
    /// bounded — microseconds, twice per modifier press, against a tap timeout
    /// measured in seconds — and it is what buys the property that this process
    /// observes no typing at all outside a hold. Delivery is gated on `active`
    /// independently, so a late enable costs a missed detection, never a wrong
    /// one.
    ///
    /// Held across the call: it must not interleave with the enable applied at
    /// tap creation, or a hold that starts while the tap is being built ends up
    /// with the two disagreeing.
    func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.active = active
        guard let port = tap?.port else { return }
        CGEvent.tapEnable(tap: port, enable: active)
    }

    @MainActor
    private func createTap() {
        guard shouldRun else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: Self.eventMask,
                callback: keyDownObserverCallback,
                userInfo: refcon
            )
        else {
            log.error("Key-down observer tap creation failed; retrying")
            scheduleRetry()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil

        // Created disabled: it may only listen while the modifier is held.
        CGEvent.tapEnable(tap: port, enable: false)

        let handle = EventTapHandle(port: port)
        let loop = EventTapRunLoop()
        lock.lock()
        tap = handle
        runLoop = loop
        lock.unlock()

        loop.start(tap: handle, name: "app.hotkeys.keydown-observer", enabled: false)

        // Applied after the thread is up and under the lock, because a hold can
        // begin while the tap is being built: reading the flag before the
        // servicing thread exists would let the worker's enable overwrite a
        // `setActive` that had already run.
        lock.lock()
        CGEvent.tapEnable(tap: port, enable: active)
        lock.unlock()

        log.info("Key-down observer tap created")
    }

    @MainActor
    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.createTap()
            }
        }
    }

    fileprivate func deliverKeyDown() {
        lock.lock()
        let handler = active ? self.handler : nil
        lock.unlock()
        handler?()
    }

    fileprivate func handleTapDisabled() {
        lock.lock()
        let port = tap?.port
        let shouldListen = active
        lock.unlock()

        guard let port, shouldListen else { return }
        log.warning("Key-down observer tap disabled by system; re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

private let keyDownObserverCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let observer = Unmanaged<KeyDownObserver>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        observer.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        observer.deliverKeyDown()
    }

    // A listen-only tap's return value is ignored; passing the event through is
    // the only correct expression of that.
    return Unmanaged.passUnretained(event)
}
