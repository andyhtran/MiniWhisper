import Foundation
import Testing

@testable import MiniWhisper

/// The rebuild decision for a tap that still reports itself as enabled. Getting
/// this wrong in either direction is costly: a false positive tears down a
/// healthy tap every watchdog tick, a false negative leaves the shortcut
/// silently dead until the app restarts.
struct TapStarvationPolicyTests {
    private let starved = TapStarvationPolicy.starvedLatencyUs + 1
    private let healthy: Float = 250  // µs, a normal serviced tap

    @Test func idleKeyboardAloneIsNotStarvation() {
        #expect(
            !TapStarvationPolicy.isStarved(
                silentFor: TapStarvationPolicy.silenceThreshold + 60,
                reportedLatencyUs: healthy))
    }

    @Test func highLatencyOnARecentlyActiveTapIsNotStarvation() {
        #expect(!TapStarvationPolicy.isStarved(silentFor: 1, reportedLatencyUs: starved))
    }

    @Test func silenceAndQueuedEventsTogetherMeanStarvation() {
        #expect(
            TapStarvationPolicy.isStarved(
                silentFor: TapStarvationPolicy.silenceThreshold + 1,
                reportedLatencyUs: starved))
    }

    /// No entry in the window server's list is missing evidence, not evidence
    /// of starvation.
    @Test func anUnreportedTapIsNeverJudgedStarved() {
        #expect(
            !TapStarvationPolicy.isStarved(
                silentFor: TapStarvationPolicy.silenceThreshold + 1_000,
                reportedLatencyUs: nil))
    }

    @Test func thresholdsAreExclusive() {
        #expect(
            !TapStarvationPolicy.isStarved(
                silentFor: TapStarvationPolicy.silenceThreshold,
                reportedLatencyUs: TapStarvationPolicy.starvedLatencyUs + 1))
        #expect(
            !TapStarvationPolicy.isStarved(
                silentFor: TapStarvationPolicy.silenceThreshold + 1,
                reportedLatencyUs: TapStarvationPolicy.starvedLatencyUs))
    }

    /// Guards the two constants themselves: the latency bar has to sit above
    /// the window server's own per-event tap timeout, and the silence bar well
    /// above a plausible pause in typing.
    @Test func thresholdsStayInTheirIntendedRange() {
        #expect(TapStarvationPolicy.starvedLatencyUs >= 5_000_000)
        #expect(TapStarvationPolicy.silenceThreshold >= 60)
    }
}
