import Foundation
import Testing
@testable import MiniWhisper

@Suite("Update state")
@MainActor
struct UpdateStateTests {
    @Test func viewModelDefaultsToIdle() {
        let model = UpdateViewModel()
        #expect(model.state.isIdle)
        #expect(model.state.phase == .idle)
    }

    @Test func phaseMatchesCase() {
        #expect(UpdateState.idle.phase == .idle)
        #expect(UpdateState.checking(.init(cancel: {})).phase == .checking)
        #expect(
            UpdateState.updateAvailable(
                .init(version: "1.0", byteCount: nil, install: {}, dismiss: {})
            ).phase == .updateAvailable)
        #expect(
            UpdateState.downloading(
                .init(cancel: {}, expectedLength: nil, receivedLength: 0)
            ).phase == .downloading)
        #expect(UpdateState.extracting(.init(progress: 0)).phase == .extracting)
        #expect(UpdateState.installing.phase == .installing)
        #expect(UpdateState.notFound(.init(acknowledge: {})).phase == .notFound)
        #expect(
            UpdateState.failed(.init(message: "boom", dismiss: {})).phase
                == .failed)
    }

    @Test func manualChecksOnlyStartFromIdleOrTerminalStates() {
        #expect(UpdateState.idle.allowsManualCheck)
        #expect(!UpdateState.checking(.init(cancel: {})).allowsManualCheck)
        #expect(
            !UpdateState.updateAvailable(
                .init(version: "1.0", byteCount: nil, install: {}, dismiss: {})
            ).allowsManualCheck)
        #expect(
            !UpdateState.downloading(
                .init(cancel: {}, expectedLength: nil, receivedLength: 0)
            ).allowsManualCheck)
        #expect(!UpdateState.extracting(.init(progress: 0)).allowsManualCheck)
        #expect(!UpdateState.installing.allowsManualCheck)
        #expect(UpdateState.notFound(.init(acknowledge: {})).allowsManualCheck)
        #expect(UpdateState.failed(.init(message: "boom", dismiss: {})).allowsManualCheck)
    }

    @Test func cancelInvokesCheckingCancellation() {
        var canceled = false
        UpdateState.checking(.init(cancel: { canceled = true })).cancel()
        #expect(canceled)
    }

    @Test func cancelDismissesAvailableUpdate() {
        var installed = false
        var dismissed = false
        UpdateState.updateAvailable(.init(
            version: "1.0", byteCount: nil,
            install: { installed = true },
            dismiss: { dismissed = true }
        )).cancel()
        #expect(dismissed)
        #expect(!installed)
    }

    @Test func cancelStopsDownload() {
        var canceled = false
        UpdateState.downloading(.init(
            cancel: { canceled = true }, expectedLength: 100, receivedLength: 10
        )).cancel()
        #expect(canceled)
    }

    @Test func cancelAcknowledgesNotFound() {
        var acknowledged = false
        UpdateState.notFound(.init(acknowledge: { acknowledged = true })).cancel()
        #expect(acknowledged)
    }

    @Test func cancelDismissesFailure() {
        var dismissed = false
        UpdateState.failed(.init(message: "boom", dismiss: { dismissed = true }))
            .cancel()
        #expect(dismissed)
    }

    @Test func downloadFractionRequiresExpectedLength() {
        let unknown = UpdateState.Downloading(
            cancel: {}, expectedLength: nil, receivedLength: 500)
        #expect(unknown.fraction == nil)

        let zero = UpdateState.Downloading(
            cancel: {}, expectedLength: 0, receivedLength: 500)
        #expect(zero.fraction == nil)
    }

    @Test func downloadFractionIsRatioCappedAtOne() throws {
        let half = UpdateState.Downloading(
            cancel: {}, expectedLength: 200, receivedLength: 100)
        #expect(try #require(half.fraction) == 0.5)

        // Sparkle documents that the expected length can undershoot the
        // actual download size.
        let over = UpdateState.Downloading(
            cancel: {}, expectedLength: 200, receivedLength: 300)
        #expect(try #require(over.fraction) == 1.0)
    }
}
