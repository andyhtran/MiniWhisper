import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Carbon's four modifier bits, the only ones `RegisterEventHotKey` understands.
/// Fn is deliberately absent — the OS hot-key API has no representation for it.
enum CarbonModifierMask {
    static func from(command: Bool, option: Bool, control: Bool, shift: Bool) -> UInt32 {
        var mask: UInt32 = 0
        if command { mask |= UInt32(cmdKey) }
        if option { mask |= UInt32(optionKey) }
        if control { mask |= UInt32(controlKey) }
        if shift { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Every combination of the four modifiers. A hot key registered once per
    /// entry fires no matter what the user happens to be holding, which is how
    /// modifier-insensitive shortcuts are expressed against an API that only
    /// matches exact chords.
    static let allCombinations: [UInt32] = {
        let bits = [UInt32(cmdKey), UInt32(optionKey), UInt32(controlKey), UInt32(shiftKey)]
        return (0..<(1 << bits.count)).map { combination in
            bits.enumerated().reduce(UInt32(0)) { mask, entry in
                combination & (1 << entry.offset) != 0 ? mask | entry.element : mask
            }
        }
    }()
}

/// Which delivery mechanism can serve a given shortcut.
///
/// The split exists because the two mechanisms have opposite trade-offs: Carbon
/// hot keys never join the event-delivery path (so they cannot stall input for
/// the system) but cannot express a bare modifier, while an event tap can see
/// bare modifiers but does sit in that path.
enum ShortcutBackend: Equatable {
    /// A key plus zero or more modifiers — registrable as a Carbon hot key.
    case carbon(keyCode: UInt16, carbonModifiers: UInt32)

    /// A bare modifier press such as Fn/Globe, which only ever surfaces as a
    /// `.flagsChanged` event and so needs the modifier tap.
    case modifierOnly

    /// Neither mechanism can serve it; the shortcut is dropped with a log line.
    case unsupported(UnsupportedReason)

    enum UnsupportedReason: Equatable {
        /// Fn combined with a regular key. Carbon cannot match Fn, and
        /// registering the chord without it would swallow the bare key
        /// system-wide — so a user holding Fn to type Fn+W would stop being
        /// able to type W anywhere.
        case fnChord

        /// A bare modifier key carrying other modifiers. Not expressible as a
        /// hot key, and the modifier tap only tracks Fn on its own.
        case modifierChord
    }

    static func classify(_ shortcut: CustomShortcut) -> ShortcutBackend {
        if shortcut.isFnOnly { return .modifierOnly }
        if FnKeyCode.isFnKey(shortcut.keyCode) { return .unsupported(.modifierChord) }
        // Deliberately `usesFnAsModifier`, not `fn`: a stored Fn flag on a
        // function-group key is an artefact of how those keys report, and
        // treating it as a real chord would silently retire arrow and F-key
        // shortcuts saved by older builds.
        if shortcut.usesFnAsModifier { return .unsupported(.fnChord) }

        return .carbon(
            keyCode: shortcut.keyCode,
            carbonModifiers: CarbonModifierMask.from(
                command: shortcut.command,
                option: shortcut.option,
                control: shortcut.control,
                shift: shortcut.shift
            )
        )
    }
}

extension CustomShortcut {
    /// No backend can serve this binding, so it will never fire. Surfaced in the
    /// UI: the row still renders a perfectly ordinary-looking shortcut, and
    /// without a marker the only clue is that pressing it does nothing.
    var needsRerecording: Bool {
        if case .unsupported = ShortcutBackend.classify(self) { return true }
        return false
    }
}

extension CustomShortcutName {
    /// Fires regardless of which modifiers are held. Cancel is the escape hatch
    /// from an in-flight recording, and the trigger that started that recording
    /// is usually still held down when the user reaches for it — requiring an
    /// exact chord would make it unreachable in exactly the case it exists for.
    var ignoresModifiers: Bool { self == .cancelRecording }
}

/// One registrable chord. Several bindings may share a `name` — that is how a
/// modifier-insensitive shortcut is expressed (one registration per modifier
/// combination).
struct HotKeyBinding: Hashable, Sendable {
    let name: CustomShortcutName
    let keyCode: UInt16
    let carbonModifiers: UInt32
}

/// Turns the configured shortcuts into the exact list of chords to register.
///
/// Two shortcuts can want the same chord — most easily when a modifier-
/// insensitive shortcut expands over every modifier combination and one of
/// those combinations is another shortcut's exact chord. Only one registration
/// can win, and the OS decides by arrival order, so the list has to be built in
/// a fixed order with an explicit rule or which shortcut works varies from run
/// to run.
enum HotKeyBindingPlan {
    struct Request: Equatable {
        let name: CustomShortcutName
        let keyCode: UInt16
        let carbonModifiers: UInt32
        /// Expands to one binding per modifier combination instead of one exact
        /// chord.
        let ignoresModifiers: Bool
    }

    struct Resolution: Equatable {
        /// In registration order. Free of internal collisions.
        let bindings: [HotKeyBinding]
        /// Dropped because a higher-precedence binding claimed the same chord.
        let shadowed: [HotKeyBinding]
    }

    /// Precedence: a shortcut asking for one exact chord beats a modifier-
    /// insensitive expansion that merely happens to cover it — the expansion is
    /// a convenience, the exact chord is what the user recorded. Ties between
    /// two exact chords go to whichever shortcut is declared first, so the
    /// winner never changes between launches.
    static func resolve(_ requests: [Request]) -> Resolution {
        let declarationOrder = Dictionary(
            uniqueKeysWithValues: CustomShortcutName.allCases.enumerated().map { ($1, $0) })
        let ranked = requests.enumerated().sorted { lhs, rhs in
            if lhs.element.ignoresModifiers != rhs.element.ignoresModifiers {
                return !lhs.element.ignoresModifiers
            }
            let lhsOrder = declarationOrder[lhs.element.name] ?? .max
            let rhsOrder = declarationOrder[rhs.element.name] ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.offset < rhs.offset
        }

        var claimed: Set<Chord> = []
        var bindings: [HotKeyBinding] = []
        var shadowed: [HotKeyBinding] = []

        for request in ranked.map(\.element) {
            let modifierSets =
                request.ignoresModifiers
                ? CarbonModifierMask.allCombinations : [request.carbonModifiers]

            for modifiers in modifierSets {
                let binding = HotKeyBinding(
                    name: request.name, keyCode: request.keyCode, carbonModifiers: modifiers)
                if claimed.insert(Chord(keyCode: request.keyCode, modifiers: modifiers)).inserted {
                    bindings.append(binding)
                } else {
                    shadowed.append(binding)
                }
            }
        }

        return Resolution(bindings: bindings, shadowed: shadowed)
    }

    private struct Chord: Hashable {
        let keyCode: UInt16
        let modifiers: UInt32
    }
}

/// Decides whether an event tap is needed at all, and how invasive it may be.
enum ModifierTapPolicy {
    /// Exactly `.flagsChanged`. Widening this mask puts the app back into the
    /// delivery path for ordinary typing, which is what this layer exists to
    /// avoid — modifier keys are inert on their own, so nothing else is needed
    /// to recognise a bare-modifier shortcut.
    static let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    /// No bare-modifier shortcut bound means no tap is created at all, and the
    /// app stays entirely out of the event chain.
    static func needsTap(hasModifierOnlyShortcut: Bool) -> Bool {
        hasModifierOnlyShortcut
    }

    /// A listen-only tap is never waited on by the window server, so it cannot
    /// stall input system-wide; a filter tap can. Only ask for the filter when
    /// the modifier press must be hidden from everything else.
    static func tapOption(suppressesModifierPress: Bool) -> CGEventTapOptions {
        suppressesModifierPress ? .defaultTap : .listenOnly
    }
}

/// Press/release bookkeeping shared by both backends.
///
/// Invariant: a release only reports true if this tracker saw the matching
/// press. Hold-to-talk stop actions run off the release, so without this a
/// stray release (repeat, or a press that was gated out) could stop a recording
/// that was never started, or stop one twice.
struct HotKeyPressTracker {
    private var pressed: Set<CustomShortcutName> = []

    /// True when this is a fresh press and the key-down action should run.
    mutating func press(_ name: CustomShortcutName) -> Bool {
        pressed.insert(name).inserted
    }

    /// True when the matching press was seen and the key-up action should run.
    mutating func release(_ name: CustomShortcutName) -> Bool {
        pressed.remove(name) != nil
    }

    func isPressed(_ name: CustomShortcutName) -> Bool {
        pressed.contains(name)
    }

    /// Drops presses that can no longer be released and reports them, in
    /// declaration order.
    ///
    /// A hot key unregistered while it is held never delivers its release — the
    /// OS simply stops matching the chord — so a hold-style action would run
    /// until the app quit. Anything dropped here has to be completed by hand.
    mutating func drainStranded(keeping live: Set<CustomShortcutName>) -> [CustomShortcutName] {
        let stranded = CustomShortcutName.allCases.filter {
            pressed.contains($0) && !live.contains($0)
        }
        pressed.subtract(stranded)
        return stranded
    }

    mutating func reset() {
        pressed.removeAll()
    }
}
