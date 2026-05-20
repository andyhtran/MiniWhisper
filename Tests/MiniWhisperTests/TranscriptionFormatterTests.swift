@testable import MiniWhisper
import Testing

struct TranscriptionFormatterTests {
    @Test func preserveCaseReplacementRunsAfterCasualLowercase() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [
                ReplacementRule(
                    find: "mini whisper",
                    replace: "MiniWhisper",
                    preserveCase: true
                ),
            ],
            capitalization: .casual,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: false,
            appendTrailingSpace: false
        )

        #expect(TranscriptionFormatter.format("I use mini whisper daily", options: options) == "i use MiniWhisper daily")
    }

    @Test func ordinaryReplacementStillFeedsFormatting() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [ReplacementRule(find: "mini whisper", replace: "MiniWhisper")],
            capitalization: .casual,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: false,
            appendTrailingSpace: false
        )

        #expect(TranscriptionFormatter.format("I use mini whisper daily", options: options) == "i use miniwhisper daily")
    }
}
