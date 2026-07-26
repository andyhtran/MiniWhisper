import Testing

@testable import MiniWhisper

// Results are bound to locals before `#expect`: the macro rewrites the call
// into a closure taking an immutable copy, which cannot invoke mutating members.
struct HotKeyPressTrackerTests {
    @Test func pressThenReleaseCompletesAHoldToTalkCycle() {
        var tracker = HotKeyPressTracker()

        let pressed = tracker.press(.toggleRecording)
        #expect(pressed)
        #expect(tracker.isPressed(.toggleRecording))

        let released = tracker.release(.toggleRecording)
        #expect(released)
        #expect(!tracker.isPressed(.toggleRecording))
    }

    /// A repeat press must not restart an in-flight recording.
    @Test func repeatPressIsSuppressed() {
        var tracker = HotKeyPressTracker()

        let first = tracker.press(.toggleRecording)
        let second = tracker.press(.toggleRecording)

        #expect(first)
        #expect(!second)
        #expect(tracker.isPressed(.toggleRecording))
    }

    /// Guards the invariant that a stop never runs without its matching start.
    @Test func releaseWithoutPressIsIgnored() {
        var tracker = HotKeyPressTracker()

        let released = tracker.release(.toggleRecording)
        #expect(!released)
    }

    @Test func secondReleaseIsIgnored() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.editSelection)
        let first = tracker.release(.editSelection)
        let second = tracker.release(.editSelection)

        #expect(first)
        #expect(!second)
    }

    @Test func pressIsAcceptedAgainAfterRelease() {
        var tracker = HotKeyPressTracker()

        let first = tracker.press(.toggleRecording)
        let released = tracker.release(.toggleRecording)
        let second = tracker.press(.toggleRecording)

        #expect(first)
        #expect(released)
        #expect(second)
    }

    @Test func shortcutsAreTrackedIndependently() {
        var tracker = HotKeyPressTracker()

        let toggle = tracker.press(.toggleRecording)
        let cancel = tracker.press(.cancelRecording)
        let releasedToggle = tracker.release(.toggleRecording)

        #expect(toggle)
        #expect(cancel)
        #expect(releasedToggle)
        #expect(tracker.isPressed(.cancelRecording))
        #expect(!tracker.isPressed(.toggleRecording))
    }

    /// A hot key unregistered mid-hold never delivers its release, so the press
    /// has to be completed here or every later press of it reads as a repeat.
    @Test func droppedRegistrationStrandsItsPress() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.toggleRecording)
        _ = tracker.press(.editSelection)

        let stranded = tracker.drainStranded(keeping: [.editSelection])

        #expect(stranded == [.toggleRecording])
        #expect(!tracker.isPressed(.toggleRecording))
        #expect(tracker.isPressed(.editSelection))
    }

    @Test func stillRegisteredPressesAreLeftAlone() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.toggleRecording)
        let stranded = tracker.drainStranded(keeping: [.toggleRecording, .cancelRecording])

        #expect(stranded.isEmpty)
        #expect(tracker.isPressed(.toggleRecording))
    }

    @Test func aShortcutThatWasNotHeldIsNotReportedAsStranded() {
        var tracker = HotKeyPressTracker()

        #expect(tracker.drainStranded(keeping: []).isEmpty)
    }

    /// Draining is what fires the key-up handlers, so a second refresh must not
    /// fire them again.
    @Test func strandedPressesAreReportedOnlyOnce() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.toggleRecording)

        #expect(tracker.drainStranded(keeping: []) == [.toggleRecording])
        #expect(tracker.drainStranded(keeping: []).isEmpty)
    }

    /// What `stop()` relies on: with nothing live, every held press comes back
    /// to be completed instead of being silently dropped.
    @Test func drainingAgainstAnEmptyLiveSetReturnsEveryHeldPress() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.toggleRecording)
        _ = tracker.press(.cancelRecording)

        let stranded = tracker.drainStranded(keeping: [])

        #expect(Set(stranded) == [.toggleRecording, .cancelRecording])
        #expect(!tracker.isPressed(.toggleRecording))
        #expect(!tracker.isPressed(.cancelRecording))
    }

    @Test func strandedPressesAreReportedInDeclarationOrder() {
        var tracker = HotKeyPressTracker()

        for name in CustomShortcutName.allCases.reversed() {
            _ = tracker.press(name)
        }

        #expect(tracker.drainStranded(keeping: []) == CustomShortcutName.allCases)
    }

    /// `stop()` resets the tracker; a release arriving afterwards must not fire
    /// a handler for a press that belonged to the previous session.
    @Test func resetDropsEveryHeldShortcut() {
        var tracker = HotKeyPressTracker()

        _ = tracker.press(.toggleRecording)
        _ = tracker.press(.editSelection)

        tracker.reset()

        let staleToggle = tracker.release(.toggleRecording)
        let staleEdit = tracker.release(.editSelection)

        #expect(!tracker.isPressed(.toggleRecording))
        #expect(!staleToggle)
        #expect(!staleEdit)
    }
}
