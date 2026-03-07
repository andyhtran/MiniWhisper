import Foundation
import Carbon.HIToolbox
import AppKit

// Fn reports as keyCode 63 on built-in keyboards and 179 on some external keyboards
enum FnKeyCode {
    static let keyCodes: Set<UInt16> = [63, 179]
    static func isFnKey(_ keyCode: UInt16) -> Bool { keyCodes.contains(keyCode) }
}

extension CGEventFlags {
    var modifierFlags: NSEvent.ModifierFlags {
        var m = NSEvent.ModifierFlags()
        if contains(.maskCommand) { m.insert(.command) }
        if contains(.maskAlternate) { m.insert(.option) }
        if contains(.maskControl) { m.insert(.control) }
        if contains(.maskShift) { m.insert(.shift) }
        return m
    }
}

struct CustomShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let command: Bool
    let option: Bool
    let control: Bool
    let shift: Bool
    let fn: Bool

    init(
        keyCode: UInt16,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        fn: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.fn = fn
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, fnPressed: Bool) -> Bool {
        guard self.keyCode == keyCode else { return false }
        return self.command == modifiers.contains(.command)
            && self.option == modifiers.contains(.option)
            && self.control == modifiers.contains(.control)
            && self.shift == modifiers.contains(.shift)
            && self.fn == fnPressed
    }

    var compactDisplayString: String {
        var str = ""
        if control { str += "⌃" }
        if option { str += "⌥" }
        if shift { str += "⇧" }
        if command { str += "⌘" }
        if fn { str += "Fn+" }
        str += keyCodeDisplayName
        return str
    }

    var keyCodeDisplayName: String {
        Self.keyCodeToDisplayName(keyCode)
    }

    var isFnOnly: Bool {
        FnKeyCode.isFnKey(keyCode) && !command && !option && !control && !shift
    }

    static func keyCodeToDisplayName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Del"
        case kVK_Escape: return "esc"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PgUp"
        case kVK_PageDown: return "PgDn"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case 179: return "Fn"
        case 63: return "Fn"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - Shortcut Names

enum CustomShortcutName: String, Codable, CaseIterable {
    case toggleRecording
    case cancelRecording
}

// MARK: - Shortcut Storage

final class CustomShortcutStorage {
    private static let storageKey = "MiniWhisperShortcuts"

    static func loadAll() -> [CustomShortcutName: CustomShortcut] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stringKeyed = try? JSONDecoder().decode([String: CustomShortcut].self, from: data)
        else {
            return defaultShortcuts()
        }

        var result: [CustomShortcutName: CustomShortcut] = [:]
        for (key, value) in stringKeyed {
            if let name = CustomShortcutName(rawValue: key) {
                result[name] = value
            }
        }

        for name in CustomShortcutName.allCases {
            if result[name] == nil {
                result[name] = defaultShortcuts()[name]
            }
        }

        return result
    }

    static func saveAll(_ shortcuts: [CustomShortcutName: CustomShortcut]) {
        var stringKeyed: [String: CustomShortcut] = [:]
        for (key, value) in shortcuts {
            stringKeyed[key.rawValue] = value
        }
        if let data = try? JSONEncoder().encode(stringKeyed) {
            UserDefaults.standard.set(data, forKey: storageKey)

        }
    }

    static func get(_ name: CustomShortcutName) -> CustomShortcut? {
        loadAll()[name]
    }

    static func set(_ shortcut: CustomShortcut?, for name: CustomShortcutName) {
        var shortcuts = loadAll()
        if let shortcut = shortcut {
            shortcuts[name] = shortcut
        } else {
            shortcuts.removeValue(forKey: name)
        }
        saveAll(shortcuts)
    }

    static func defaultShortcuts() -> [CustomShortcutName: CustomShortcut] {
        [
            .toggleRecording: CustomShortcut(keyCode: UInt16(kVK_ANSI_Grave), option: true),  // Option + `
            .cancelRecording: CustomShortcut(keyCode: UInt16(kVK_Escape)),  // Escape
        ]
    }
}
