import Testing
@testable import MiniWhisper

struct WhisperProviderTests {
    @Test func transcriptionUsesEnglishWithTimestampedSegments() {
        let options = WhisperContext.transcriptionOptions()

        switch options.language {
        case .fixed(let language):
            #expect(language == "en")
        case .auto:
            Issue.record("Expected Whisper language to be pinned to English")
        }
        #expect(!options.detectLanguage)
        #expect(!options.noTimestamps)
        #expect(!options.singleSegment)
        #expect(options.threadCount >= 1)
    }
}
