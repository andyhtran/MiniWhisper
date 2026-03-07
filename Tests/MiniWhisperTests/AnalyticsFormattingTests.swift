import Testing
@testable import MiniWhisper

struct AnalyticsFormattingTests {
    @Test(arguments: [
        (0, "0"),
        (999, "999"),
        (1000, "1.0K"),
        (1500, "1.5K"),
        (10000, "10K"),
        (999999, "1000K"),
        (1_000_000, "1.0M"),
        (1_500_000, "1.5M"),
        (10_000_000, "10M"),
    ] as [(Int, String)])
    func compactNumber(value: Int, expected: String) {
        #expect(AnalyticsStore.compactNumber(value) == expected)
    }

    @Test(arguments: [
        (0, "0:00"),
        (59, "0:59"),
        (60, "1:00"),
        (3599, "59:59"),
        (3600, "1h 0m"),
        (3660, "1h 1m"),
        (86400, "1d 0h"),
        (90000, "1d 1h"),
    ] as [(Int, String)])
    func formatDuration(seconds: Int, expected: String) {
        #expect(AnalyticsStore.formatDuration(seconds) == expected)
    }

    @Test(arguments: [
        (100, 59.0, 0),
        (100, 60.0, 100),
        (150, 120.0, 75),
        (0, 120.0, 0),
    ] as [(Int, Double, Int)])
    func calculateWPM(words: Int, duration: Double, expected: Int) {
        #expect(AnalyticsStore.calculateWPM(totalWords: words, totalDuration: duration) == expected)
    }
}
