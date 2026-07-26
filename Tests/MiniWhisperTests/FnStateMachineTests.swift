import Testing
@testable import MiniWhisper

struct FnStateMachineTests {
    private func makeSM() -> FnStateMachine { FnStateMachine() }

    @Test func tapDownThenUpReturnsFnKeyUp() {
        let sm = makeSM()
        let downOk = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        #expect(downOk)
        #expect(sm.isFnKeyDown)

        let result = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 100_000_000) // 100ms
        #expect(result == .fnKeyUp)
        #expect(!sm.isFnKeyDown)
    }

    @Test func keyUpWithoutKeyDownReturnsNone() {
        let sm = makeSM()
        let result = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 0)
        #expect(result == .none)
    }

    @Test func usedAsModifierReturnsDifferentResult() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        _ = sm.markUsedAsModifier()

        let result = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 100_000_000)
        #expect(result == .usedAsModifier)
    }

    @Test func duplicateKeyDownReturnsFalse() {
        let sm = makeSM()
        #expect(sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0))
        #expect(!sm.processFnKeyDown(captureTime: 0, hwTimestamp: 100_000_000))
    }

    @Test func stuckKeyDownRecoversAfterFiveSeconds() {
        let sm = makeSM()
        // Down whose matching keyUp the OS dropped (sleep/wake, app switch).
        #expect(sm.processFnKeyDown(captureTime: 0, hwTimestamp: 1_000_000_000))

        // >5s later the stale down-state must be discarded and this press
        // accepted as new.
        let downOk = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 7_000_000_000)
        #expect(downOk)
        #expect(sm.isFnKeyDown)

        // The recovered press completes a normal tap.
        let result = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 7_100_000_000)
        #expect(result == .fnKeyUp)
    }

    @Test func repeatKeyDownUnderStuckThresholdIsStillRejected() {
        let sm = makeSM()
        #expect(sm.processFnKeyDown(captureTime: 0, hwTimestamp: 1_000_000_000))
        // 2s later — a genuine held key, not a stuck state.
        #expect(!sm.processFnKeyDown(captureTime: 0, hwTimestamp: 3_000_000_000))
    }

    @Test func longHoldReleaseStillReturnsFnKeyUp() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 1_000_000_000)
        // 3s hold — duration is deliberately irrelevant on release.
        let result = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 4_000_000_000)
        #expect(result == .fnKeyUp)
    }

    @Test func resetClearsAllState() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.setActiveFnOnlyShortcut(.toggleRecording)

        sm.reset()

        #expect(!sm.isFnKeyDown)
        #expect(sm.clearActiveFnOnlyShortcut() == nil)
    }

    @Test func setAndClearActiveFnOnlyShortcut() {
        let sm = makeSM()
        sm.setActiveFnOnlyShortcut(.toggleRecording)
        let cleared = sm.clearActiveFnOnlyShortcut()
        #expect(cleared == .toggleRecording)

        // Second clear returns nil
        #expect(sm.clearActiveFnOnlyShortcut() == nil)
    }

    @Test func markUsedAsModifierReturnsAndClearsActiveShortcut() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.setActiveFnOnlyShortcut(.toggleRecording)

        let returned = sm.markUsedAsModifier()
        #expect(returned == .toggleRecording)

        // Active shortcut was cleared
        #expect(sm.clearActiveFnOnlyShortcut() == nil)
    }

    /// The Fn+← case: an ordinary key going down while Fn is held retires the
    /// action the press started, and the release must not then run it a second
    /// time or report itself as a plain tap.
    @Test func aKeyPressedDuringTheHoldRetiresTheShortcutExactlyOnce() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.setActiveFnOnlyShortcut(.toggleRecording)

        // Observer sees the arrow key.
        #expect(sm.markUsedAsModifier() == .toggleRecording)
        // A second key during the same hold has nothing left to retire.
        #expect(sm.markUsedAsModifier() == nil)

        let release = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 100_000_000)
        #expect(release == .usedAsModifier)
        #expect(sm.clearActiveFnOnlyShortcut() == nil)
    }

    /// After macOS drops an Fn key-up, the press it belonged to is still held.
    /// The recovering press has to be able to find and complete it, or the
    /// tracker rejects the new press as a repeat and the user's tap does
    /// nothing at all.
    @Test func stuckDownRecoveryLeavesTheAbandonedPressRecoverable() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 1_000_000_000)
        sm.setActiveFnOnlyShortcut(.toggleRecording)
        // The matching key-up never arrives.

        #expect(sm.processFnKeyDown(captureTime: 0, hwTimestamp: 7_000_000_000))
        #expect(sm.clearActiveFnOnlyShortcut() == .toggleRecording)
    }

    /// Reading which shortcut is in flight must not hand over responsibility for
    /// completing it — that belongs to `clearActiveFnOnlyShortcut()`.
    @Test func readingTheActiveShortcutDoesNotClearIt() {
        let sm = makeSM()
        sm.setActiveFnOnlyShortcut(.toggleRecording)

        #expect(sm.activeFnOnlyShortcutName == .toggleRecording)
        #expect(sm.activeFnOnlyShortcutName == .toggleRecording)
        #expect(sm.clearActiveFnOnlyShortcut() == .toggleRecording)
        #expect(sm.activeFnOnlyShortcutName == nil)
    }

    /// A hold with no other key is still an ordinary trigger, however long.
    @Test func aHoldWithNoOtherKeyStillCompletesTheShortcut() {
        let sm = makeSM()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.setActiveFnOnlyShortcut(.toggleRecording)

        let release = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 2_000_000_000)

        #expect(release == .fnKeyUp)
        #expect(sm.clearActiveFnOnlyShortcut() == .toggleRecording)
    }
}

/// macOS fires its own "press 🌐 to…" action on the *release*, so a press hidden
/// from the system followed by a delivered release triggers exactly what hiding
/// the press was meant to prevent.
struct FnPressSwallowSymmetryTests {
    @Test func aSwallowedPressMakesItsReleaseSwallowedToo() {
        let sm = FnStateMachine()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.recordPressSwallowed(true)

        _ = sm.processFnKeyUp(captureTime: 0, hwTimestamp: 100_000_000)
        #expect(sm.consumePressSwallowed())
    }

    @Test func aPressLeftAloneLeavesItsReleaseAlone() {
        let sm = FnStateMachine()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.recordPressSwallowed(false)

        #expect(!sm.consumePressSwallowed())
    }

    /// Symmetry holds even when the hold turned out to be modifier use: the
    /// system never saw the press either way.
    @Test func symmetryHoldsWhenFnWasUsedAsAModifier() {
        let sm = FnStateMachine()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.recordPressSwallowed(true)
        _ = sm.markUsedAsModifier()

        #expect(sm.processFnKeyUp(captureTime: 0, hwTimestamp: 100_000_000) == .usedAsModifier)
        #expect(sm.consumePressSwallowed())
    }

    /// A stray release with no press behind it must not be swallowed on the
    /// strength of an older one.
    @Test func theSwallowDecisionIsConsumed() {
        let sm = FnStateMachine()
        sm.recordPressSwallowed(true)

        #expect(sm.consumePressSwallowed())
        #expect(!sm.consumePressSwallowed())
    }

    @Test func resetClearsAPendingSwallowDecision() {
        let sm = FnStateMachine()
        _ = sm.processFnKeyDown(captureTime: 0, hwTimestamp: 0)
        sm.recordPressSwallowed(true)

        sm.reset()

        #expect(!sm.consumePressSwallowed())
    }
}
