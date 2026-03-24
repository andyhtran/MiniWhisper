import Foundation
import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class ParakeetProvider {
    private nonisolated(unsafe) var asrManager: AsrManager?
    private var initializationTask: Task<Void, Error>?

    var isInitialized: Bool { asrManager != nil }

    func unload() {
        asrManager = nil
        initializationTask = nil
    }

    func initialize() async throws {
        if asrManager != nil { return }

        if let existing = initializationTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            asrManager = manager
        }
        initializationTask = task

        do {
            try await task.value
        } catch {
            initializationTask = nil
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if asrManager == nil {
            try await initialize()
        }

        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        let startTime = Date()

        nonisolated(unsafe) let unsafeManager = manager
        let result = try await unsafeManager.transcribe(audioURL, source: .microphone)
        let processingTime = Date().timeIntervalSince(startTime)

        let segments = convertToSegments(result)

        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            segments: segments,
            language: "en",
            duration: processingTime,
            model: "parakeet-tdt-v3"
        )
    }

    private func convertToSegments(_ result: ASRResult) -> [TranscriptionSegment] {
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            return [TranscriptionSegment(
                start: 0,
                end: result.duration,
                text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                words: nil
            )]
        }

        var words: [WordTiming] = []
        var currentWord = ""
        var wordStart: TimeInterval = 0
        var wordEnd: TimeInterval = 0
        var wordConfidences: [Float] = []

        for timing in tokenTimings {
            let token = timing.token
            let startsNewWord = token.hasPrefix(" ") || token.hasPrefix("▁") || (words.isEmpty && currentWord.isEmpty)

            if startsNewWord && !currentWord.isEmpty {
                let avgConfidence = wordConfidences.isEmpty ? 1.0 : wordConfidences.reduce(0, +) / Float(wordConfidences.count)
                words.append(WordTiming(
                    word: currentWord,
                    start: wordStart,
                    end: wordEnd,
                    probability: avgConfidence
                ))
                currentWord = ""
                wordConfidences = []
            }

            let cleanToken = token.trimmingCharacters(in: CharacterSet(charactersIn: " ▁"))
            if currentWord.isEmpty {
                wordStart = timing.startTime
            }
            currentWord += cleanToken
            wordEnd = timing.endTime
            wordConfidences.append(timing.confidence)
        }

        if !currentWord.isEmpty {
            let avgConfidence = wordConfidences.isEmpty ? 1.0 : wordConfidences.reduce(0, +) / Float(wordConfidences.count)
            words.append(WordTiming(
                word: currentWord,
                start: wordStart,
                end: wordEnd,
                probability: avgConfidence
            ))
        }

        guard !words.isEmpty else { return [] }

        let segment = TranscriptionSegment(
            start: words.first?.start ?? 0,
            end: words.last?.end ?? result.duration,
            text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            words: words
        )

        return [segment]
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Transcription model not loaded"
        }
    }
}
