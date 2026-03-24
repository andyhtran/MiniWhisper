import Testing
import Carbon.HIToolbox
import CoreGraphics
import AppKit
@testable import MiniWhisper

struct CustomShortcutMatchTests {
    // kVK_ANSI_Grave = 50, kVK_ANSI_K = 40
    static let optionGrave = CustomShortcut(keyCode: UInt16(kVK_ANSI_Grave), option: true)
    static let fnK = CustomShortcut(keyCode: UInt16(kVK_ANSI_K), fn: true)

    @Test func exactMatchSucceeds() {
        #expect(Self.optionGrave.matches(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .option, fnPressed: false))
    }

    @Test func extraFnBreaksMatch() {
        #expect(!Self.optionGrave.matches(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .option, fnPressed: true))
    }

    @Test func missingModifierBreaksMatch() {
        #expect(!Self.optionGrave.matches(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [], fnPressed: false))
    }

    @Test func wrongKeyCodeBreaksMatch() {
        #expect(!Self.optionGrave.matches(keyCode: UInt16(kVK_ANSI_A), modifiers: .option, fnPressed: false))
    }

    @Test func fnModifierMatchSucceeds() {
        #expect(Self.fnK.matches(keyCode: UInt16(kVK_ANSI_K), modifiers: [], fnPressed: true))
    }

    @Test func missingFnBreaksMatch() {
        #expect(!Self.fnK.matches(keyCode: UInt16(kVK_ANSI_K), modifiers: [], fnPressed: false))
    }
}

struct CustomShortcutDisplayTests {
    @Test func optionGraveDisplayString() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_ANSI_Grave), option: true)
        #expect(shortcut.compactDisplayString == "Option+`")
    }

    @Test func allModifiersDisplayInOrder() {
        let shortcut = CustomShortcut(
            keyCode: UInt16(kVK_ANSI_K),
            command: true, option: true, control: true, shift: true
        )
        #expect(shortcut.compactDisplayString == "Ctrl+Option+Shift+Cmd+K")
    }

    @Test func fnPrefixDisplayString() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_ANSI_K), fn: true)
        #expect(shortcut.compactDisplayString == "Fn+K")
    }

    @Test func escapeAloneDisplayString() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_Escape))
        #expect(shortcut.compactDisplayString == "esc")
    }
}

struct CustomShortcutFnOnlyTests {
    @Test func fnKeyCode63IsFnOnly() {
        let shortcut = CustomShortcut(keyCode: 63)
        #expect(shortcut.isFnOnly)
    }

    @Test func fnKeyCode179IsFnOnly() {
        let shortcut = CustomShortcut(keyCode: 179)
        #expect(shortcut.isFnOnly)
    }

    @Test func fnKeyWithModifierIsNotFnOnly() {
        let shortcut = CustomShortcut(keyCode: 63, command: true)
        #expect(!shortcut.isFnOnly)
    }

    @Test func regularKeyIsNotFnOnly() {
        let shortcut = CustomShortcut(keyCode: UInt16(kVK_ANSI_K))
        #expect(!shortcut.isFnOnly)
    }
}

struct KeyCodeDisplayNameTests {
    @Test(arguments: [
        (UInt16(kVK_ANSI_A), "A"),
        (UInt16(kVK_Escape), "esc"),
        (UInt16(kVK_Space), "Space"),
        (UInt16(63), "Fn"),
        (UInt16(179), "Fn"),
        (UInt16(999), "Key 999"),
    ] as [(UInt16, String)])
    func keyCodeToDisplayName(keyCode: UInt16, expected: String) {
        #expect(CustomShortcut.keyCodeToDisplayName(keyCode) == expected)
    }
}

struct FnKeyCodeTests {
    @Test func recognizesFnKeyCodes() {
        #expect(FnKeyCode.isFnKey(63))
        #expect(FnKeyCode.isFnKey(179))
    }

    @Test func rejectsNonFnKeyCodes() {
        #expect(!FnKeyCode.isFnKey(0))
        #expect(!FnKeyCode.isFnKey(64))
    }
}

struct CGEventFlagsConversionTests {
    @Test func commandFlagConverts() {
        let flags = CGEventFlags.maskCommand
        #expect(flags.modifierFlags == .command)
    }

    @Test func optionFlagConverts() {
        let flags = CGEventFlags.maskAlternate
        #expect(flags.modifierFlags == .option)
    }

    @Test func combinedFlagsConvert() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        #expect(flags.modifierFlags == [.command, .shift])
    }

    @Test func emptyFlagsConvert() {
        let flags = CGEventFlags()
        #expect(flags.modifierFlags == [])
    }
}
