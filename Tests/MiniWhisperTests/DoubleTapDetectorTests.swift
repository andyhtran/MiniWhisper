import Testing
import Carbon.HIToolbox
@testable import MiniWhisper

struct DoubleTapDetectorTests {
    // Right Option = 61, Left Option = 58
    private func makeDetector() -> DoubleTapDetector {
        // Explicit windows so the time math in the tests is unambiguous.
        DoubleTapDetector(maxTapDuration: 0.4, doubleTapWindow: 0.3)
    }

    @Test func singleCleanTapReturnsTap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
    }

    @Test func twoFastTapsReturnDoubleTap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        d.modifierDown(keyCode: 61, time: 0.2)
        #expect(d.modifierUp(keyCode: 61, time: 0.3) == .doubleTap)
    }

    @Test func secondTapTooLateIsJustAnotherTap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        // gap from first release (0.1) to second release (0.5) = 0.4 > 0.3 window
        d.modifierDown(keyCode: 61, time: 0.4)
        #expect(d.modifierUp(keyCode: 61, time: 0.5) == .tap)
    }

    @Test func heldTooLongIsNotATap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        // held 0.5 > 0.4 maxTapDuration
        #expect(d.modifierUp(keyCode: 61, time: 0.5) == .none)
    }

    @Test func usedAsModifierIsNotATap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        d.noteOtherKeyDown()  // e.g. ⌥+C combo
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .none)
    }

    @Test func keyBetweenTapsBreaksDoubleTap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        d.noteOtherKeyDown()  // a key was typed between the two taps
        d.modifierDown(keyCode: 61, time: 0.2)
        #expect(d.modifierUp(keyCode: 61, time: 0.3) == .tap)
    }

    @Test func releaseWithoutDownReturnsNone() {
        let d = makeDetector()
        #expect(d.modifierUp(keyCode: 61, time: 0) == .none)
    }

    @Test func differentKeysDoNotPairIntoDoubleTap() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        // Left Option this time — different physical key, so no double-tap.
        d.modifierDown(keyCode: 58, time: 0.2)
        #expect(d.modifierUp(keyCode: 58, time: 0.3) == .tap)
    }

    @Test func clearTapChainPreventsPairing() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        d.clearTapChain()
        d.modifierDown(keyCode: 61, time: 0.2)
        #expect(d.modifierUp(keyCode: 61, time: 0.3) == .tap)
    }

    @Test func resetClearsChain() {
        let d = makeDetector()
        d.modifierDown(keyCode: 61, time: 0)
        #expect(d.modifierUp(keyCode: 61, time: 0.1) == .tap)
        d.reset()
        d.modifierDown(keyCode: 61, time: 0.2)
        #expect(d.modifierUp(keyCode: 61, time: 0.3) == .tap)
    }
}

struct CustomShortcutDoubleTapTests {
    @Test func doubleTapDisplayString() {
        #expect(CustomShortcut(keyCode: 61, doubleTap: true).compactDisplayString == "Double-tap Right ⌥")
        #expect(CustomShortcut(keyCode: 58, doubleTap: true).compactDisplayString == "Double-tap Left ⌥")
    }

    @Test func modifierKeyCodeDisplayNames() {
        #expect(CustomShortcut.keyCodeToDisplayName(61) == "Right ⌥")
        #expect(CustomShortcut.keyCodeToDisplayName(58) == "Left ⌥")
        #expect(CustomShortcut.keyCodeToDisplayName(55) == "Left ⌘")
    }

    @Test func doubleTapNeverMatchesAsCombo() {
        let s = CustomShortcut(keyCode: 61, doubleTap: true)
        #expect(!s.matches(keyCode: 61, modifiers: [], fnPressed: false))
        #expect(!s.matches(keyCode: 61, modifiers: .option, fnPressed: false))
    }

    @Test func doubleTapIsNotFnOnly() {
        #expect(!CustomShortcut(keyCode: 63, doubleTap: true).isFnOnly)
    }

    @Test func encodeDecodeRoundTrips() throws {
        let s = CustomShortcut(keyCode: 61, doubleTap: true)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(CustomShortcut.self, from: data)
        #expect(back == s)
        #expect(back.doubleTap)
    }

    // Shortcuts persisted before `doubleTap` existed lack the key; they must
    // still decode (defaulting doubleTap to false) rather than throw.
    @Test func legacyJSONWithoutDoubleTapDecodes() throws {
        let json = #"{"keyCode":50,"command":false,"option":true,"control":false,"shift":false,"fn":false}"#
        let decoded = try JSONDecoder().decode(CustomShortcut.self, from: Data(json.utf8))
        #expect(decoded.keyCode == 50)
        #expect(decoded.option)
        #expect(!decoded.doubleTap)
    }

    @Test func modifierKeyCodeFlagPresence() {
        #expect(ModifierKeyCode.flagPresent(forKeyCode: 61, in: .maskAlternate))
        #expect(!ModifierKeyCode.flagPresent(forKeyCode: 61, in: .maskCommand))
        #expect(ModifierKeyCode.isModifierKey(61))
        #expect(!ModifierKeyCode.isModifierKey(63))  // Fn is handled separately
    }
}
