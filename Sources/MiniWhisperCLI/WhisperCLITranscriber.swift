import Foundation
@preconcurrency import AVFoundation
import whisper

enum WhisperLanguageChoice: Equatable {
    case auto
    case fixed(String)

    var displayValue: String {
        switch self {
        case .auto: return "auto"
        case .fixed(let language): return language
        }
    }

    static func parse(_ value: String) throws -> WhisperLanguageChoice {
        if value == "auto" {
            return .auto
        }

        let isLanguageCode = value.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil
        guard isLanguageCode else {
            throw CLIError.usage("Invalid language: \(value). Expected `auto` or a language code like `en`, `es`, or `ja`.")
        }

        return .fixed(value.lowercased())
    }
}

enum WhisperAlignmentMode: String, Equatable {
    case none
    case token = "whisper-token"
    case dtw = "whisper-dtw"

    var displayValue: String { rawValue }
    var needsWordTimestamps: Bool { self != .none }
    var needsDTW: Bool { self == .dtw }

    static func parse(_ value: String) throws -> WhisperAlignmentMode {
        guard let mode = WhisperAlignmentMode(rawValue: value) else {
            throw CLIError.usage("Invalid align mode: \(value). Expected none, whisper-token, or whisper-dtw.")
        }
        return mode
    }
}

private struct WhisperTokenTiming {
    let text: String
    let startTime: Double
    let endTime: Double
    let confidence: Float
}

struct WhisperCLIResult {
    let text: String
    let language: String
    let audioDuration: Double
    let processingTime: Double
    let model: String
    let segments: [SegmentTimingOutput]
    let wordTimings: [WordTimingOutput]
}

private final class CLIWhisperInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class CLIWhisperContext: @unchecked Sendable {
    private let context: OpaquePointer
    private let vadModelPath: String?

    private init(context: OpaquePointer, vadModelPath: String?) {
        self.context = context
        self.vadModelPath = vadModelPath
    }

    static func load(
        modelPath: String,
        vadModelPath: String?,
        alignmentMode: WhisperAlignmentMode
    ) throws -> CLIWhisperContext {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = !alignmentMode.needsDTW
        params.dtw_token_timestamps = alignmentMode.needsDTW
        if alignmentMode.needsDTW {
            params.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        }

        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperCLIError.modelLoadFailed
        }

        return CLIWhisperContext(context: context, vadModelPath: vadModelPath)
    }

    func transcribe(
        samples: [Float],
        language: WhisperLanguageChoice,
        alignmentMode: WhisperAlignmentMode,
        useVAD: Bool
    ) throws -> (text: String, language: String, segments: [SegmentTimingOutput], wordTimings: [WordTimingOutput]) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        var languageCString: UnsafeMutablePointer<CChar>?
        var vadCString: UnsafeMutablePointer<CChar>?

        switch language {
        case .auto:
            // whisper.cpp treats nil/empty/"auto" language as transcription
            // auto-detection; `detect_language` is a separate language-only mode.
            params.language = nil
            params.detect_language = false
        case .fixed(let languageCode):
            languageCString = strdup(languageCode)
            params.language = languageCString.map { UnsafePointer($0) }
            params.detect_language = false
        }

        if useVAD, let vadModelPath {
            vadCString = strdup(vadModelPath)
            params.vad = true
            params.vad_model_path = vadCString.map { UnsafePointer($0) }
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.5
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        }

        defer {
            if let languageCString { free(languageCString) }
            if let vadCString { free(vadCString) }
        }

        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = false
        params.single_segment = false
        params.no_context = true
        params.token_timestamps = alignmentMode.needsWordTimestamps
        params.temperature = 0.0
        params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else {
            throw WhisperCLIError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var text = ""
        var segments: [SegmentTimingOutput] = []
        for index in 0..<segmentCount {
            if let cString = whisper_full_get_segment_text(context, index) {
                let segmentText = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
                text += String(cString: cString)
                let start = Double(whisper_full_get_segment_t0(context, index)) / 100
                let end = Double(whisper_full_get_segment_t1(context, index)) / 100
                if !segmentText.isEmpty {
                    segments.append(SegmentTimingOutput(startTime: start, endTime: end, text: segmentText))
                }
            }
        }

        let wordTimings = alignmentMode.needsWordTimestamps
            ? extractWordTimings(segmentCount: segmentCount)
            : []

        let languageID = whisper_full_lang_id(context)
        let detectedLanguage: String
        if let languageString = whisper_lang_str(languageID) {
            detectedLanguage = String(cString: languageString)
        } else {
            detectedLanguage = language.displayValue
        }

        return (text, detectedLanguage, segments, wordTimings)
    }

    private func extractWordTimings(segmentCount: Int32) -> [WordTimingOutput] {
        var tokenTimings: [WhisperTokenTiming] = []

        for segmentIndex in 0..<segmentCount {
            let tokenCount = whisper_full_n_tokens(context, segmentIndex)
            for tokenIndex in 0..<tokenCount {
                guard let tokenCString = whisper_full_get_token_text(context, segmentIndex, tokenIndex) else {
                    continue
                }

                let text = String(cString: tokenCString)
                guard shouldUseToken(text) else { continue }

                let tokenData = whisper_full_get_token_data(context, segmentIndex, tokenIndex)
                let startTime = Double(tokenData.t0) / 100
                let endTime = Double(tokenData.t1) / 100
                guard startTime.isFinite, endTime.isFinite, endTime > startTime else {
                    continue
                }

                tokenTimings.append(
                    WhisperTokenTiming(
                        text: text,
                        startTime: startTime,
                        endTime: endTime,
                        confidence: tokenData.p
                    )
                )
            }
        }

        return WhisperWordTimingBuilder.mergeTokensIntoWords(tokenTimings)
    }

    private func shouldUseToken(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.hasPrefix("[") && text.hasSuffix("]") { return false }
        if text.allSatisfy({ $0.isWhitespace }) { return false }
        return true
    }

    deinit {
        whisper_free(context)
    }
}

private enum WhisperWordTimingBuilder {
    private static let tokenBoundaryCharacters = CharacterSet(charactersIn: " \n\t▁")

    static func mergeTokensIntoWords(_ tokenTimings: [WhisperTokenTiming]) -> [WordTimingOutput] {
        guard !tokenTimings.isEmpty else { return [] }

        var words: [WordTimingOutput] = []
        var currentWord = ""
        var currentStart: Double?
        var currentEnd = 0.0
        var confidences: [Float] = []

        for timing in tokenTimings {
            let startsNewWord = timing.text.hasPrefix(" ")
                || timing.text.hasPrefix("\n")
                || timing.text.hasPrefix("\t")
                || timing.text.hasPrefix("▁")

            if startsNewWord, !currentWord.isEmpty, let start = currentStart {
                words.append(
                    WordTimingOutput(
                        word: currentWord,
                        startTime: start,
                        endTime: currentEnd,
                        confidence: average(confidences)
                    )
                )
                currentWord = ""
                confidences = []
                currentStart = nil
            }

            let cleanToken = timing.text.trimmingCharacters(in: tokenBoundaryCharacters)
            guard !cleanToken.isEmpty else { continue }
            if currentStart == nil || currentWord.isEmpty {
                currentStart = timing.startTime
            }
            currentWord += cleanToken
            currentEnd = timing.endTime
            confidences.append(timing.confidence)
        }

        if !currentWord.isEmpty, let start = currentStart {
            words.append(
                WordTimingOutput(
                    word: currentWord,
                    startTime: start,
                    endTime: currentEnd,
                    confidence: average(confidences)
                )
            )
        }

        return words
    }

    private static func average(_ confidences: [Float]) -> Float {
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Float(confidences.count)
    }
}

enum WhisperCLITranscriber {
    static let modelName = "whisper-large-v3-turbo"

    static func installModels(quiet: Bool) async throws {
        try await ensureModels(quiet: quiet)
    }

    static func transcribe(
        audioURL: URL,
        language: WhisperLanguageChoice,
        alignmentMode: WhisperAlignmentMode,
        quiet: Bool,
        channel: AudioChannelSelection = .mix
    ) async throws -> WhisperCLIResult {
        try await ensureModels(quiet: quiet)

        if !quiet {
            Console.error("Loading \(modelName)...")
        }

        let vadPath = FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperVADModel.path)
            ? MiniWhisperPaths.whisperVADModel.path
            : nil
        let context = try CLIWhisperContext.load(
            modelPath: MiniWhisperPaths.whisperModel.path,
            vadModelPath: vadPath,
            alignmentMode: alignmentMode
        )

        if !quiet {
            let alignment = alignmentMode == .none ? "none" : alignmentMode.displayValue
            Console.error("Transcribing \(audioURL.path) (batch, model: whisper, language: \(language.displayValue), align: \(alignment))...")
        }

        let samples = try resampleTo16kHz(audioURL: audioURL, channel: channel)
        let audioDuration = AudioMetadata.durationSeconds(for: audioURL) ?? 0
        let start = Date()
        // VAD compacts audio before decode, and whisper.cpp token timestamps stay on that compacted timeline.
        let useVAD = vadPath != nil && !alignmentMode.needsWordTimestamps
        var result = try await Task.detached {
            try context.transcribe(samples: samples, language: language, alignmentMode: alignmentMode, useVAD: useVAD)
        }.value
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           useVAD,
           hasAudibleSignal(samples) {
            if !quiet {
                Console.error("Whisper VAD produced an empty transcript; retrying without VAD...")
            }
            result = try await Task.detached {
                try context.transcribe(samples: samples, language: language, alignmentMode: alignmentMode, useVAD: false)
            }.value
        }
        let processingTime = Date().timeIntervalSince(start)

        return WhisperCLIResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: result.language,
            audioDuration: audioDuration,
            processingTime: processingTime,
            model: modelName,
            segments: result.segments,
            wordTimings: result.wordTimings
        )
    }

    private static func ensureModels(quiet: Bool) async throws {
        try FileManager.default.createDirectory(at: MiniWhisperPaths.whisperModels, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperModel.path) {
            if !quiet {
                Console.error("Downloading \(modelName) to \(MiniWhisperPaths.whisperModel.path)...")
            }
            try await download(
                from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!,
                to: MiniWhisperPaths.whisperModel
            )
        }

        if !FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperVADModel.path) {
            if !quiet {
                Console.error("Downloading Whisper VAD model to \(MiniWhisperPaths.whisperVADModel.path)...")
            }
            try await download(
                from: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
                to: MiniWhisperPaths.whisperVADModel
            )
        }
    }

    private static func download(from url: URL, to destination: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw WhisperCLIError.downloadFailed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    /// AVAudioConverter silently drops non-zero channels instead of downmixing,
    /// so channels are folded to mono here before resampling.
    static func resampleTo16kHz(
        audioURL: URL,
        channel: AudioChannelSelection = .mix
    ) throws -> [Float] {
        let audioFile = try AVAudioFile(
            forReading: audioURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputFormat = audioFile.processingFormat

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw WhisperCLIError.resampleFailed
        }
        try audioFile.read(into: inputBuffer)

        let mono = try foldToMono(inputBuffer, channel: channel)

        if inputFormat.sampleRate == 16_000 {
            return mono
        }
        return try resampleMono(mono, from: inputFormat.sampleRate)
    }

    /// Collapse a multi-channel buffer to a single float array at the source rate.
    private static func foldToMono(
        _ buffer: AVAudioPCMBuffer,
        channel: AudioChannelSelection
    ) throws -> [Float] {
        guard let data = buffer.floatChannelData else {
            throw WhisperCLIError.resampleFailed
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        switch channel {
        case .index(let requested):
            guard requested < channels else {
                throw WhisperCLIError.channelOutOfRange(requested: requested, available: channels)
            }
            return Array(UnsafeBufferPointer(start: data[requested], count: frames))

        case .mix:
            if channels == 1 {
                return Array(UnsafeBufferPointer(start: data[0], count: frames))
            }
            // Average, not sum: summing two correlated channels clips.
            var mixed = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channels)
            for channelIndex in 0..<channels {
                let samples = data[channelIndex]
                for frame in 0..<frames {
                    mixed[frame] += samples[frame] * scale
                }
            }
            return mixed
        }
    }

    private static func resampleMono(_ samples: [Float], from sourceRate: Double) throws -> [Float] {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw WhisperCLIError.resampleFailed
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WhisperCLIError.resampleFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            sourceBuffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        guard let resampler = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WhisperCLIError.resampleFailed
        }

        let ratio = 16_000 / sourceRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw WhisperCLIError.resampleFailed
        }

        let inputState = CLIWhisperInputState(buffer: sourceBuffer)
        var error: NSError?
        resampler.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputState.consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputState.consumed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }
        if let error { throw error }

        let pointer = outputBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: pointer, count: Int(outputBuffer.frameLength)))
    }

    private static func hasAudibleSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let sumSquares = samples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        return rms > 0.001
    }
}

enum WhisperCLIError: LocalizedError {
    case modelLoadFailed
    case transcriptionFailed
    case downloadFailed
    case resampleFailed
    case channelOutOfRange(requested: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load Whisper model."
        case .transcriptionFailed: return "Whisper transcription failed."
        case .downloadFailed: return "Failed to download Whisper model."
        case .resampleFailed: return "Failed to resample audio for Whisper."
        case .channelOutOfRange(let requested, let available):
            let plural = available == 1 ? "channel" : "channels"
            return "Channel \(requested) requested but the file has \(available) \(plural) (0-\(available - 1))."
        }
    }
}

/// Which channels of a multi-channel file feed transcription.
enum AudioChannelSelection: Equatable {
    case mix
    case index(Int)

    static func parse(_ value: String) -> AudioChannelSelection? {
        if value == "mix" { return .mix }
        guard let index = Int(value), index >= 0 else { return nil }
        return .index(index)
    }

    var label: String {
        switch self {
        case .mix: return "mix"
        case .index(let index): return String(index)
        }
    }
}
