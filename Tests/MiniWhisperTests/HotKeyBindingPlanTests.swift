import Carbon.HIToolbox
import Testing

@testable import MiniWhisper

struct HotKeyBindingPlanTests {
    private func exact(
        _ name: CustomShortcutName, _ keyCode: Int, modifiers: UInt32 = 0
    ) -> HotKeyBindingPlan.Request {
        .init(
            name: name, keyCode: UInt16(keyCode), carbonModifiers: modifiers,
            ignoresModifiers: false)
    }

    private func expanded(_ name: CustomShortcutName, _ keyCode: Int) -> HotKeyBindingPlan.Request {
        .init(name: name, keyCode: UInt16(keyCode), carbonModifiers: 0, ignoresModifiers: true)
    }

    @Test func exactRequestBecomesOneBinding() {
        let plan = HotKeyBindingPlan.resolve([
            exact(.toggleRecording, kVK_ANSI_W, modifiers: UInt32(optionKey))
        ])

        #expect(
            plan.bindings == [
                HotKeyBinding(
                    name: .toggleRecording, keyCode: UInt16(kVK_ANSI_W),
                    carbonModifiers: UInt32(optionKey))
            ])
        #expect(plan.shadowed.isEmpty)
    }

    @Test func modifierInsensitiveRequestExpandsOverEveryCombination() {
        let plan = HotKeyBindingPlan.resolve([expanded(.cancelRecording, kVK_Escape)])

        #expect(plan.bindings.count == 16)
        #expect(Set(plan.bindings.map(\.carbonModifiers)).count == 16)
        #expect(plan.shadowed.isEmpty)
    }

    /// The collision that actually happens: cancel expands over every modifier
    /// combination, and one of those combinations is another shortcut's chord.
    @Test func exactChordBeatsAnExpansionCombination() {
        let plan = HotKeyBindingPlan.resolve([
            expanded(.cancelRecording, kVK_Escape),
            exact(.toggleRecording, kVK_Escape, modifiers: UInt32(optionKey)),
        ])

        let contested = plan.bindings.filter {
            $0.keyCode == UInt16(kVK_Escape) && $0.carbonModifiers == UInt32(optionKey)
        }
        #expect(contested.map(\.name) == [.toggleRecording])
        #expect(plan.bindings.count == 16)  // cancel keeps the other 15
        #expect(
            plan.shadowed == [
                HotKeyBinding(
                    name: .cancelRecording, keyCode: UInt16(kVK_Escape),
                    carbonModifiers: UInt32(optionKey))
            ])
    }

    /// Registration order decides who wins a contested chord, so the plan must
    /// not depend on the order it happened to be handed.
    @Test func precedenceIsIndependentOfRequestOrder() {
        let requests = [
            expanded(.cancelRecording, kVK_Escape),
            exact(.toggleRecording, kVK_Escape, modifiers: UInt32(optionKey)),
        ]

        #expect(HotKeyBindingPlan.resolve(requests) == HotKeyBindingPlan.resolve(requests.reversed()))
    }

    /// Two shortcuts on the same chord: whichever is declared first wins, so the
    /// same one works on every launch.
    @Test func tiesBetweenExactChordsGoToDeclarationOrder() {
        let requests = [
            exact(.editSelection, kVK_ANSI_E, modifiers: UInt32(optionKey)),
            exact(.toggleRecording, kVK_ANSI_E, modifiers: UInt32(optionKey)),
        ]

        let plan = HotKeyBindingPlan.resolve(requests)

        #expect(plan.bindings.map(\.name) == [.toggleRecording])
        #expect(plan.shadowed.map(\.name) == [.editSelection])
        #expect(HotKeyBindingPlan.resolve(requests.reversed()) == plan)
    }

    /// Exact chords must be offered to the OS before any expansion, since first
    /// asker wins.
    @Test func exactChordsAreRegisteredBeforeExpansions() {
        let plan = HotKeyBindingPlan.resolve([
            expanded(.cancelRecording, kVK_Escape),
            exact(.toggleRecording, kVK_ANSI_W, modifiers: UInt32(optionKey)),
        ])

        #expect(plan.bindings.first?.name == .toggleRecording)
    }

    @Test func unrelatedShortcutsAllSurvive() {
        let plan = HotKeyBindingPlan.resolve([
            exact(.toggleRecording, kVK_ANSI_W, modifiers: UInt32(optionKey)),
            exact(.autoCleanupRecording, kVK_ANSI_R, modifiers: UInt32(optionKey)),
            exact(.editSelection, kVK_ANSI_E, modifiers: UInt32(optionKey)),
        ])

        #expect(plan.bindings.count == 3)
        #expect(plan.shadowed.isEmpty)
    }

    @Test func emptyRequestListPlansNothing() {
        let plan = HotKeyBindingPlan.resolve([])

        #expect(plan.bindings.isEmpty)
        #expect(plan.shadowed.isEmpty)
    }
}

struct HotKeyHandlerGateTests {
    /// Fail closed: a chord registered with no handler behind it is swallowed
    /// system-wide with nothing able to act on it.
    @Test func installFailureLeavesTheGateShut() {
        var gate = HotKeyHandlerGate()

        #expect(!gate.ensureInstalled { false })
        #expect(!gate.isInstalled)
    }

    @Test func successOpensTheGate() {
        var gate = HotKeyHandlerGate()

        #expect(gate.ensureInstalled { true })
        #expect(gate.isInstalled)
    }

    @Test func handlerIsInstalledOnlyOnce() {
        var gate = HotKeyHandlerGate()
        var installs = 0

        for _ in 0..<3 {
            _ = gate.ensureInstalled {
                installs += 1
                return true
            }
        }

        #expect(installs == 1)
    }

    /// A failed install must not be permanent — the next registration tries
    /// again rather than leaving every shortcut dead for the session.
    @Test func failureIsRetriedOnTheNextAttempt() {
        var gate = HotKeyHandlerGate()
        var attempts = 0

        let first = gate.ensureInstalled {
            attempts += 1
            return false
        }
        let second = gate.ensureInstalled {
            attempts += 1
            return true
        }

        #expect(!first)
        #expect(second)
        #expect(attempts == 2)
    }
}
