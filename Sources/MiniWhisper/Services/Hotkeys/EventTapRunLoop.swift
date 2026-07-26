import CoreGraphics
import Foundation

/// Hosts a CGEventTap's run-loop source on a private thread.
///
/// A filter tap is serviced synchronously: the window server hands the event to
/// the tap and holds it until the callback returns or the tap times out. If the
/// source lives on the main run loop, every keystroke in the session — in every
/// app — waits behind whatever else the main thread is doing, and a long enough
/// stall gets the tap silently disabled. A thread that does nothing but service
/// the tap removes that coupling.
///
/// Warning: the callback still runs on this thread, so it must not block on
/// another one. Blocking here reintroduces exactly the stall the thread exists
/// to prevent.
/// A tap being handed to the thread that will service it.
///
/// `CFMachPort` is not `Sendable`, but the handoff this box marks is a transfer,
/// not sharing: the port is created, then given to exactly one servicing thread
/// before that thread starts. The operations the owner keeps performing on it
/// afterwards — enable, check enabled, invalidate — are thread-safe CF calls
/// that carry no per-thread state, which is what makes the transfer sound.
struct EventTapHandle: @unchecked Sendable {
    let port: CFMachPort
}

final class EventTapRunLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var running = false

    /// Adds `tap` to a freshly started thread's run loop and enables it.
    func start(tap: EventTapHandle, name: String, enabled: Bool = true) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        stopped = false
        lock.unlock()

        let worker = Thread { [weak self] in
            guard let self else { return }

            let loop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap.port, 0)
            CFRunLoopAddSource(loop, source, .commonModes)

            self.lock.lock()
            self.runLoop = loop
            self.lock.unlock()

            CGEvent.tapEnable(tap: tap.port, enable: enabled)

            while !self.isStopped() {
                // Returns .stopped when `stop()` wakes the loop, and .finished
                // once the port is invalidated and no sources are left — either
                // way there is nothing further to service.
                if CFRunLoopRunInMode(.defaultMode, 1.0e10, false) == .finished { break }
            }

            CFRunLoopRemoveSource(loop, source, .commonModes)

            self.lock.lock()
            self.runLoop = nil
            self.running = false
            self.lock.unlock()
        }

        worker.name = name
        worker.qualityOfService = .userInteractive
        worker.stackSize = 512 * 1024
        worker.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let loop = runLoop
        lock.unlock()

        if let loop { CFRunLoopStop(loop) }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
