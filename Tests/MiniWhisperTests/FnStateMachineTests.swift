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
}
