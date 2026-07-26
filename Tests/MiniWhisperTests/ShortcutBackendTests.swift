import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import MiniWhisper

struct ShortcutBackendClassificationTests {
    @Test func chordWithModifiersGoesToCarbon() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_ANSI_W), option: true)

        #expect(
            ShortcutBackend.classify(shortcut)
                == .carbon(keyCode: UInt16(kVK_ANSI_W), carbonModifiers: UInt32(optionKey)))
    }

    @Test func bareKeyGoesToCarbonWithNoModifiers() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_Escape))

        #expect(
            ShortcutBackend.classify(shortcut)
                == .carbon(keyCode: UInt16(kVK_Escape), carbonModifiers: 0))
    }

    @Test(arguments: [UInt16(63), UInt16(179)])
    func bareFnGoesToModifierTap(keyCode: UInt16) {
        #expect(ShortcutBackend.classify(CustomShortcut(keyCode: keyCode)) == .modifierOnly)
    }

    /// Registering the chord without Fn would swallow the bare key everywhere,
    /// so refusing it is the safe outcome.
    @Test func fnPlusRegularKeyIsUnsupported() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_ANSI_W), fn: true)

        #expect(ShortcutBackend.classify(shortcut) == .unsupported(.fnChord))
    }

    @Test func fnKeyCarryingOtherModifiersIsUnsupported() {
        let shortcut = CustomShortcut(keyCode: 63, command: true)

        #expect(ShortcutBackend.classify(shortcut) == .unsupported(.modifierChord))
    }

    /// Older builds stored `fn: true` for every function-group key, because the
    /// system reports the flag for them whether or not Fn was held. Reading
    /// those back as Fn chords would retire working shortcuts on upgrade.
    @Test(arguments: [
        UInt16(kVK_UpArrow), UInt16(kVK_DownArrow), UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
        UInt16(kVK_F1), UInt16(kVK_F5), UInt16(kVK_F12),
        UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        UInt16(kVK_ForwardDelete),
    ])
    func storedFnFlagOnFunctionGroupKeyIsNormalisedToAPlainChord(keyCode: UInt16) {
        let migrated = CustomShortcut(keyCode: keyCode, fn: true)

        #expect(ShortcutBackend.classify(migrated) == .carbon(keyCode: keyCode, carbonModifiers: 0))
        #expect(!migrated.needsRerecording)
    }

    @Test func storedFnFlagOnAFunctionGroupKeyKeepsItsOtherModifiers() {
        let migrated = CustomShortcut(keyCode: UInt16(kVK_UpArrow), option: true, fn: true)

        #expect(
            ShortcutBackend.classify(migrated)
                == .carbon(keyCode: UInt16(kVK_UpArrow), carbonModifiers: UInt32(optionKey)))
    }

    /// The one case a stored Fn flag still means something, and the one the UI
    /// has to flag: nothing can register it.
    @Test func fnChordOnAnOrdinaryKeyStillNeedsRerecording() {
        #expect(CustomShortcut(keyCode: UInt16(kVK_ANSI_W), fn: true).needsRerecording)
        #expect(CustomShortcut(keyCode: 63, command: true).needsRerecording)
        #expect(!CustomShortcut(keyCode: UInt16(kVK_ANSI_W), option: true).needsRerecording)
        #expect(!CustomShortcut(keyCode: 63).needsRerecording)
    }

    /// A normalised binding must not keep advertising a modifier it ignores.
    @Test func migratedFunctionGroupShortcutDropsFnFromItsDisplayString() {
        #expect(CustomShortcut(keyCode: UInt16(kVK_UpArrow), fn: true).compactDisplayString == "↑")
        #expect(CustomShortcut(keyCode: UInt16(kVK_ANSI_W), fn: true).compactDisplayString == "Fn+W")
    }

    /// Every default binding must land on Carbon, so a stock install needs no
    /// event tap and no Accessibility grant for its shortcuts.
    @Test func defaultShortcutsAllUseCarbon() {
        for (_, shortcut) in CustomShortcutStorage.defaultShortcuts() {
            guard case .carbon = ShortcutBackend.classify(shortcut) else {
                Issue.record("Default shortcut \(shortcut.compactDisplayString) is not a Carbon chord")
                continue
            }
        }
    }
}

struct CarbonModifierMaskTests {
    @Test func noModifiersIsZero() {
        #expect(CarbonModifierMask.from(command: false, option: false, control: false, shift: false) == 0)
    }

    @Test(arguments: [
        (true, false, false, false, UInt32(cmdKey)),
        (false, true, false, false, UInt32(optionKey)),
        (false, false, true, false, UInt32(controlKey)),
        (false, false, false, true, UInt32(shiftKey)),
    ])
    func singleModifierMapsToItsCarbonConstant(
        command: Bool, option: Bool, control: Bool, shift: Bool, expected: UInt32
    ) {
        #expect(
            CarbonModifierMask.from(
                command: command, option: option, control: control, shift: shift) == expected)
    }

    @Test func modifiersCombineAsABitmask() {
        let mask = CarbonModifierMask.from(
            command: true, option: true, control: false, shift: true)

        #expect(mask == UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey))
        #expect(mask & UInt32(controlKey) == 0)
    }

    @Test func allCombinationsCoversEveryDistinctSubset() {
        let combinations = CarbonModifierMask.allCombinations

        #expect(combinations.count == 16)
        #expect(Set(combinations).count == 16)
        #expect(combinations.contains(0))
        #expect(
            combinations.contains(
                UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey)))
    }

    /// A modifier-insensitive shortcut is expressed as one registration per
    /// combination, so the exact chord must be among them.
    @Test func allCombinationsContainsEveryExactChord() {
        for command in [false, true] {
            for option in [false, true] {
                let mask = CarbonModifierMask.from(
                    command: command, option: option, control: false, shift: false)
                #expect(CarbonModifierMask.allCombinations.contains(mask))
            }
        }
    }
}

struct FunctionKeyGroupTests {
    @Test(arguments: [
        UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4), UInt16(kVK_F5),
        UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9), UInt16(kVK_F10),
        UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        UInt16(kVK_ForwardDelete),
    ])
    func groupCoversEveryKeyThatReportsFnOnItsOwn(keyCode: UInt16) {
        #expect(FunctionKeyGroup.setsSecondaryFnIntrinsically(keyCode))
    }

    @Test(arguments: [
        UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_A), UInt16(kVK_Space), UInt16(kVK_Escape),
        UInt16(kVK_Delete), UInt16(kVK_Return), UInt16(kVK_Tab), UInt16(63), UInt16(179),
    ])
    func ordinaryKeysAreNotInTheGroup(keyCode: UInt16) {
        #expect(!FunctionKeyGroup.setsSecondaryFnIntrinsically(keyCode))
    }

    /// The recorder's guard: without this the flag arrows carry intrinsically
    /// would reject every one of them as an unbindable Fn chord.
    @Test func arrowsAndFKeysStayRecordableDespiteTheFnFlag() {
        for keyCode in [UInt16(kVK_UpArrow), UInt16(kVK_F5), UInt16(kVK_ForwardDelete)] {
            #expect(
                !FunctionKeyGroup.indicatesHeldFn(
                    keyCode: keyCode, secondaryFnFlagSet: true, fnKeyIsDown: false))
            // Even with Fn genuinely held: an Fn chord could not be bound, so
            // the plain key is the useful reading.
            #expect(
                !FunctionKeyGroup.indicatesHeldFn(
                    keyCode: keyCode, secondaryFnFlagSet: true, fnKeyIsDown: true))
        }
    }

    @Test func heldFnIsStillDetectedOnOrdinaryKeys() {
        #expect(
            FunctionKeyGroup.indicatesHeldFn(
                keyCode: UInt16(kVK_ANSI_W), secondaryFnFlagSet: true, fnKeyIsDown: false))
        #expect(
            FunctionKeyGroup.indicatesHeldFn(
                keyCode: UInt16(kVK_ANSI_W), secondaryFnFlagSet: false, fnKeyIsDown: true))
        #expect(
            !FunctionKeyGroup.indicatesHeldFn(
                keyCode: UInt16(kVK_ANSI_W), secondaryFnFlagSet: false, fnKeyIsDown: false))
    }
}

struct ShortcutModifierSensitivityTests {
    @Test func onlyCancelIgnoresModifiers() {
        #expect(CustomShortcutName.cancelRecording.ignoresModifiers)

        for name in CustomShortcutName.allCases where name != .cancelRecording {
            #expect(!name.ignoresModifiers)
        }
    }
}

struct ModifierTapPolicyTests {
    /// The whole point of the split: the tap may only ever see modifier
    /// changes. keyDown/keyUp belong to Carbon.
    @Test func maskIsFlagsChangedOnly() {
        #expect(ModifierTapPolicy.eventMask == CGEventMask(1 << CGEventType.flagsChanged.rawValue))
        #expect(ModifierTapPolicy.eventMask == 0x1000)
        #expect(ModifierTapPolicy.eventMask & CGEventMask(1 << CGEventType.keyDown.rawValue) == 0)
        #expect(ModifierTapPolicy.eventMask & CGEventMask(1 << CGEventType.keyUp.rawValue) == 0)
    }

    @Test func tapExistsOnlyForModifierOnlyShortcuts() {
        #expect(ModifierTapPolicy.needsTap(hasModifierOnlyShortcut: true))
        #expect(!ModifierTapPolicy.needsTap(hasModifierOnlyShortcut: false))
    }

    @Test func filterTapOnlyWhenThePressMustBeSuppressed() {
        #expect(ModifierTapPolicy.tapOption(suppressesModifierPress: true) == .defaultTap)
        #expect(ModifierTapPolicy.tapOption(suppressesModifierPress: false) == .listenOnly)
    }
}
