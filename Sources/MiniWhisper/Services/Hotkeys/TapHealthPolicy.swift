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

    /// One over-threshold sample is an accusation, not a conviction.
    enum Verdict: Equatable, Sendable {
        /// No evidence of starvation; any prior suspicion is withdrawn.
        case healthy
        /// First over-threshold sample. The read that produced it reset the
        /// window server's accumulator, so the next tick re-measures from a
        /// clean slate: a stale sample cannot survive to the second read, a
        /// genuine backlog can.
        case suspect
        /// Over threshold on two consecutive reads: rebuild.
        case starved
    }

    /// A rebuild needs three signals: prolonged silence, the window server
    /// reporting queued-but-unserviced events, and that report surviving a
    /// second look.
    ///
    /// The second look exists because the latency figure is least trustworthy
    /// exactly when it is consulted. After a long quiet stretch the accumulator
    /// can hold one enormous stale sample — many minutes of "latency" have been
    /// observed on macOS 26 while input was demonstrably healthy — and the
    /// silence gate means quiet stretches are the only time this code asks.
    /// Reading the list resets the accumulator, so re-checking one tick later
    /// separates the artifact from a real backlog, at the cost of one watchdog
    /// interval of extra delay before a true rebuild.
    ///
    /// `reportedLatencyUs` is nil when the tap could not be found in the window
    /// server's list, which is not evidence of starvation.
    static func verdict(
        silentFor: CFTimeInterval,
        reportedLatencyUs: Float?,
        wasSuspect: Bool
    ) -> Verdict {
        guard silentFor > silenceThreshold,
            let latency = reportedLatencyUs,
            latency > starvedLatencyUs
        else { return .healthy }
        return wasSuspect ? .starved : .suspect
    }
}
