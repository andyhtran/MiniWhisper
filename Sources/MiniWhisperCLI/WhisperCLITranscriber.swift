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

struct WhisperCLIResult {
    let text: String
    let language: String
    let audioDuration: Double
    let processingTime: Double
    let model: String
    let segments: [SegmentTimingOutput]
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

    static func load(modelPath: String, vadModelPath: String?) throws -> CLIWhisperContext {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperCLIError.modelLoadFailed
        }

        return CLIWhisperContext(context: context, vadModelPath: vadModelPath)
    }

    func transcribe(
        samples: [Float],
        language: WhisperLanguageChoice,
        useVAD: Bool
    ) throws -> (text: String, language: String, segments: [SegmentTimingOutput]) {
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

        let languageID = whisper_full_lang_id(context)
        let detectedLanguage: String
        if let languageString = whisper_lang_str(languageID) {
            detectedLanguage = String(cString: languageString)
        } else {
            detectedLanguage = language.displayValue
        }

        return (text, detectedLanguage, segments)
    }

    deinit {
        whisper_free(context)
    }
}

enum WhisperCLITranscriber {
    static let modelName = "whisper-large-v3-turbo"

    static func installModels(quiet: Bool) async throws {
        try await ensureModels(quiet: quiet)
    }

    static func transcribe(audioURL: URL, language: WhisperLanguageChoice, quiet: Bool) async throws -> WhisperCLIResult {
        try await ensureModels(quiet: quiet)

        if !quiet {
            Console.error("Loading \(modelName)...")
        }

        let vadPath = FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperVADModel.path)
            ? MiniWhisperPaths.whisperVADModel.path
            : nil
        let context = try CLIWhisperContext.load(modelPath: MiniWhisperPaths.whisperModel.path, vadModelPath: vadPath)

        if !quiet {
            Console.error("Transcribing \(audioURL.path) (batch, model: whisper, language: \(language.displayValue))...")
        }

        let samples = try resampleTo16kHz(audioURL: audioURL)
        let audioDuration = AudioMetadata.durationSeconds(for: audioURL) ?? 0
        let start = Date()
        let useVAD = vadPath != nil
        var result = try await Task.detached {
            try context.transcribe(samples: samples, language: language, useVAD: useVAD)
        }.value
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           useVAD,
           hasAudibleSignal(samples) {
            if !quiet {
                Console.error("Whisper VAD produced an empty transcript; retrying without VAD...")
            }
            result = try await Task.detached {
                try context.transcribe(samples: samples, language: language, useVAD: false)
            }.value
        }
        let processingTime = Date().timeIntervalSince(start)

        return WhisperCLIResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: result.language,
            audioDuration: audioDuration,
            processingTime: processingTime,
            model: modelName,
            segments: result.segments
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

    private static func resampleTo16kHz(audioURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(
            forReading: audioURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputFormat = audioFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperCLIError.resampleFailed
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw WhisperCLIError.resampleFailed
        }
        try audioFile.read(into: inputBuffer)

        if inputFormat.sampleRate == 16_000 && inputFormat.channelCount == 1 {
            let pointer = inputBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: pointer, count: Int(inputBuffer.frameLength)))
        }

        guard let resampler = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WhisperCLIError.resampleFailed
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw WhisperCLIError.resampleFailed
        }

        let inputState = CLIWhisperInputState(buffer: inputBuffer)
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

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load Whisper model."
        case .transcriptionFailed: return "Whisper transcription failed."
        case .downloadFailed: return "Failed to download Whisper model."
        case .resampleFailed: return "Failed to resample audio for Whisper."
        }
    }
}
