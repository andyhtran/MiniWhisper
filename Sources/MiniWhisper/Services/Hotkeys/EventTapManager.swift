import Foundation
import CoreGraphics
import ApplicationServices
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "EventTap")

final class EventTapManager: @unchecked Sendable {
    typealias EventCallback = (CGEventType, CGEvent) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var watchdogTimer: Timer?
    private var shouldRun = false
    private let callbackLock = NSLock()
    private var callback: EventCallback?
    // Written from the tap callback, read from the watchdog — both on the main
    // run loop, like the rest of this class's mutable state.
    private var lastEventTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var starvedRebuilds = 0

    // Shared between tap creation and the watchdog's CGGetEventTapList lookup:
    // the mask is how we find our own tap among this process's taps (the
    // shortcut recorder creates ephemeral taps with a different mask).
    private static let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    private static let watchdogInterval: TimeInterval = 30
    // Silence alone can't prove tap death (identical to the user not touching
    // the keyboard), so the starvation check requires both prolonged silence
    // AND WindowServer reporting queued-but-unserviced events.
    private static let staleTapInterval: CFTimeInterval = 90
    // Healthy taps report µs–ms queue latency; WindowServer's own per-event
    // tap timeout is single-digit seconds. Past 5s, events are rotting in the
    // queue while tapIsEnabled still says true.
    private static let starvedTapLatencyUs: Float = 5_000_000

    func setEventCallback(_ callback: @escaping EventCallback) {
        callbackLock.lock()
        self.callback = callback
        callbackLock.unlock()
    }

    @MainActor
    func start() {
        shouldRun = true
        guard eventTap == nil else {
            log.info("start() called but tap already exists")
            return
        }
        log.info("Starting event tap creation...")
        log.info("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        log.info("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")
        createEventTap()
        startWatchdog()
    }

    @MainActor
    func stop() {
        shouldRun = false
        retryTimer?.invalidate()
        retryTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        clearEventCallback()
        log.info("Event tap stopped")
    }

    private func currentCallback() -> EventCallback? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callback
    }

    private func clearEventCallback() {
        callbackLock.lock()
        callback = nil
        callbackLock.unlock()
    }

    @MainActor
    func reenable() {
        guard shouldRun else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            log.info("Event tap re-enabled")
        }
    }

    @MainActor
    private func createEventTap(retryCount: Int = 0) {
        guard shouldRun else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.lastEventTime = CFAbsoluteTimeGetCurrent()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Task { @MainActor in
                        log.warning("Event tap disabled by system, re-enabling")
                        manager.reenable()
                    }
                    return Unmanaged.passUnretained(event)
                }

                if let callback = manager.currentCallback() {
                    let consumed = callback(type, event)
                    return consumed ? nil : Unmanaged.passUnretained(event)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            log.error("Failed to create event tap (attempt \(retryCount + 1)/10)")
            if retryCount < 10 {
                retryTimer?.invalidate()
                retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.createEventTap(retryCount: retryCount + 1)
                    }
                }
            } else {
                log.error("Giving up after 10 retries. Check Accessibility permission in System Settings.")
            }
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastEventTime = CFAbsoluteTimeGetCurrent()
        log.info("Event tap created and enabled successfully")
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTapHealth()
            }
        }
    }

    // The tapDisabledBy* callbacks only fire while the tap is being serviced.
    // A tap can instead starve silently: still registered, tapIsEnabled still
    // true, but its events queue in WindowServer unserviced. Only a full teardown
    // + recreate recovers from that, so the watchdog checks WindowServer's view
    // of our tap rather than trusting local state.
    @MainActor
    private func checkTapHealth() {
        guard shouldRun else { return }
        guard let tap = eventTap else { return }  // creation retries handle nil

        if !CGEvent.tapIsEnabled(tap: tap) {
            log.warning("Watchdog found tap disabled; re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.error("Re-enable did not stick; recreating tap")
                recreateTap()
            }
            return
        }

        let silent = CFAbsoluteTimeGetCurrent() - lastEventTime
        if silent > Self.staleTapInterval,
           let latencyUs = reportedTapLatencyUs(), latencyUs > Self.starvedTapLatencyUs {
            starvedRebuilds += 1
            log.error("Tap starved — enabled but WindowServer queue latency \(Int(latencyUs / 1_000_000))s; recreating (rebuild #\(self.starvedRebuilds) since last healthy tick)")
            recreateTap()
            return
        }
        starvedRebuilds = 0
    }

    @MainActor
    private func recreateTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        createEventTap()
    }

    // WindowServer's per-tap queue latency, matched to our tap by pid + event
    // mask (other app features can create ephemeral taps with different masks).
    // It grows in lockstep with wall clock while an event sits undelivered —
    // the external signal that distinguishes a starved tap from an idle one.
    private func reportedTapLatencyUs() -> Float? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return nil }
        let pid = getpid()
        return taps.prefix(Int(count))
            .filter { $0.tappingProcess == pid && $0.eventsOfInterest == Self.eventMask }
            .map(\.avgUsecLatency)
            .max()
    }
}
