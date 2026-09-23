import Testing

@testable import MiniWhisper

struct SoundEffectsTests {
    @Test func playStartCallsTheInjectedPlayerWhenEnabled() {
        var startCalls = 0
        let effects = SoundEffects(
            isEnabled: { true },
            startPlayer: { startCalls += 1 },
            stopPlayer: { }
        )

        effects.playStart()

        #expect(startCalls == 1)
    }

    @Test func playStopCallsTheInjectedPlayerWhenEnabled() {
        var stopCalls = 0
        let effects = SoundEffects(
            isEnabled: { true },
            startPlayer: { },
            stopPlayer: { stopCalls += 1 }
        )

        effects.playStop()

        #expect(stopCalls == 1)
    }

    @Test func neitherPlayerRunsWhenDisabled() {
        var startCalls = 0
        var stopCalls = 0
        let effects = SoundEffects(
            isEnabled: { false },
            startPlayer: { startCalls += 1 },
            stopPlayer: { stopCalls += 1 }
        )

        effects.playStart()
        effects.playStop()

        #expect(startCalls == 0)
        #expect(stopCalls == 0)
    }

    @Test func startAndStopAreIndependent() {
        var startCalls = 0
        var stopCalls = 0
        let effects = SoundEffects(
            isEnabled: { true },
            startPlayer: { startCalls += 1 },
            stopPlayer: { stopCalls += 1 }
        )

        effects.playStart()
        effects.playStart()
        effects.playStop()

        #expect(startCalls == 2)
        #expect(stopCalls == 1)
    }
}
