import Foundation

/// When an event tap that still reports itself as enabled must be rebuilt
/// anyway.
///
/// `CGEvent.tapIsEnabled` answers "is this tap registered", not "is it being
/// serviced". A tap can starve: still registered, still enabled, but its events
/// pile up in the window server undelivered. Nothing notifies the process — the
/// `tapDisabledBy*` callbacks only arrive while a tap is still being serviced —
/// so the only way out is to notice from the outside and rebuild.
enum TapStarvationPolicy {
    /// Silence alone proves nothing: it is indistinguishable from the user not
    /// touching the keyboard. It only narrows *when* to bother asking the window
    /// server.
    static let silenceThreshold: CFTimeInterval = 90

    /// Healthy taps report µs–ms queue latency, and the window server's own
    /// per-event tap timeout is single-digit seconds. Past this, events are
    /// rotting in the queue while the tap still claims to be enabled.
    static let starvedLatencyUs: Float = 5_000_000

    /// A rebuild needs both signals: prolonged silence *and* the window server
    /// reporting queued-but-unserviced events. Either alone has a benign
    /// explanation — an idle keyboard, or a latency sample taken across a
    /// sleep/wake.
    ///
    /// `reportedLatencyUs` is nil when the tap could not be found in the window
    /// server's list, which is not evidence of starvation.
    static func isStarved(silentFor: CFTimeInterval, reportedLatencyUs: Float?) -> Bool {
        guard silentFor > silenceThreshold, let latency = reportedLatencyUs else { return false }
        return latency > starvedLatencyUs
    }
}
