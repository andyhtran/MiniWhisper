import Testing
@testable import MiniWhisper

struct MenuBarIconTests {
    // The pulse must stay in a calm mid band — never collapsing to the
    // bar-width floor and never reaching recording's full-height range, so
    // "working" stays visually distinct from "listening".
    @Test func pulseFractionsStayWithinCalmBand() {
        for phase in stride(from: 0.0, to: 1.0, by: 0.05) {
            for fraction in MenuBarIconRenderer.pulsingBarFractions(phase: phase) {
                #expect(fraction >= 0.24)
                #expect(fraction <= 0.66)
            }
        }
    }

    @Test func phaseAdvancesTheWave() {
        let start = MenuBarIconRenderer.pulsingBarFractions(phase: 0)
        let quarter = MenuBarIconRenderer.pulsingBarFractions(phase: 0.25)
        #expect(start != quarter)
    }

    @Test func barsAreOffsetFromEachOther() {
        let fractions = MenuBarIconRenderer.pulsingBarFractions(phase: 0.1)
        #expect(Set(fractions).count == fractions.count)
    }
}
