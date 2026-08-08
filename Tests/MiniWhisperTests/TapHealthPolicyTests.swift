import Foundation
import Testing

@testable import MiniWhisper

/// The rebuild decision for a tap that still reports itself as enabled. Getting
/// this wrong in either direction is costly: a false positive tears down a
/// healthy tap on a lying latency sample, a false negative leaves the shortcut
/// silently dead until the app restarts.
///
/// The verdict is deliberately two-stage. The latency figure can hold one
/// enormous stale sample after a quiet stretch — exactly the moment the
/// silence gate lets it be consulted — so one bad reading only raises
/// suspicion, and only a second consecutive bad reading convicts.
struct TapStarvationPolicyTests {
    private let overThreshold = TapStarvationPolicy.starvedLatencyUs + 1
    private let healthy: Float = 250  // µs, a normal serviced tap
    private let longSilence = TapStarvationPolicy.silenceThreshold + 60

    @Test func idleKeyboardAloneIsHealthy() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence,
                reportedLatencyUs: healthy,
                wasSuspect: false) == .healthy)
    }

    @Test func highLatencyOnARecentlyActiveTapIsHealthy() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: 1,
                reportedLatencyUs: overThreshold,
                wasSuspect: false) == .healthy)
    }

    @Test func firstOverThresholdReadingOnlyRaisesSuspicion() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence,
                reportedLatencyUs: overThreshold,
                wasSuspect: false) == .suspect)
    }

    @Test func secondConsecutiveOverThresholdReadingConvicts() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence,
                reportedLatencyUs: overThreshold,
                wasSuspect: true) == .starved)
    }

    /// The reading that raised suspicion reset the window server's accumulator,
    /// so a healthy second reading proves the first sample was stale — the
    /// suspicion must not linger and convict on some later, unrelated reading.
    @Test func aHealthySecondReadingWithdrawsSuspicion() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence,
                reportedLatencyUs: healthy,
                wasSuspect: true) == .healthy)
    }

    /// No entry in the window server's list is missing evidence, not evidence
    /// of starvation — with or without prior suspicion.
    @Test func anUnreportedTapIsNeverJudgedStarved() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence + 1_000,
                reportedLatencyUs: nil,
                wasSuspect: false) == .healthy)
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: longSilence + 1_000,
                reportedLatencyUs: nil,
                wasSuspect: true) == .healthy)
    }

    @Test func thresholdsAreExclusive() {
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: TapStarvationPolicy.silenceThreshold,
                reportedLatencyUs: overThreshold,
                wasSuspect: true) == .healthy)
        #expect(
            TapStarvationPolicy.verdict(
                silentFor: TapStarvationPolicy.silenceThreshold + 1,
                reportedLatencyUs: TapStarvationPolicy.starvedLatencyUs,
                wasSuspect: true) == .healthy)
    }

    /// Guards the two constants themselves: the latency bar has to sit above
    /// the window server's own per-event tap timeout, and the silence bar well
    /// above a plausible pause in typing.
    @Test func thresholdsStayInTheirIntendedRange() {
        #expect(TapStarvationPolicy.starvedLatencyUs >= 5_000_000)
        #expect(TapStarvationPolicy.silenceThreshold >= 60)
    }
}
