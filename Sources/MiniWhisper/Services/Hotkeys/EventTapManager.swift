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
    private var shouldRun = false
    private let callbackLock = NSLock()
    private var callback: EventCallback?

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
    }

    @MainActor
    func stop() {
        shouldRun = false
        retryTimer?.invalidate()
        retryTimer = nil

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

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()

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
        log.info("Event tap created and enabled successfully")
    }
}
