import Testing
@testable import MiniWhisper

struct WhisperProviderTests {
    @Test func transcriptionUsesAutoLanguageWithTimestampedSegments() {
        let options = WhisperContext.transcriptionOptions()

        switch options.language {
        case .fixed(let language):
            Issue.record("Expected Whisper language to use auto detection, got \(language)")
        case .auto:
            break
        }
        #expect(!options.detectLanguage)
        #expect(!options.noTimestamps)
        #expect(!options.singleSegment)
        #expect(options.threadCount >= 1)
    }
}
