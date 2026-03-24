import Testing
@testable import MiniWhisper

struct WhisperProviderTests {
    @Test func transcriptionUsesAutoDetectWithoutDetectionOnlyMode() {
        let options = WhisperContext.transcriptionOptions()

        #expect(!options.detectLanguage)
        #expect(options.noTimestamps)
        #expect(!options.singleSegment)
        #expect(options.threadCount >= 1)
    }
}
