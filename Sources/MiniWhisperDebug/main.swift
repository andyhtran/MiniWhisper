import AVFoundation
import Darwin
@preconcurrency import FluidAudio
import Foundation
import whisper

private struct WordTiming: Codable, Equatable, Hashable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let probability: Float
}

private struct TranscriptionSegment: Codable, Equatable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [WordTiming]?
}

private struct TranscriptionResult: Sendable {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String
    let duration: TimeInterval
    let model: String
}

private enum CLIError: LocalizedError {
    case usage(String)
    case missingValue(String)
    case invalidValue(flag: String, value: String)
    case invalidInputPath(String)
    case invalidPresetForEngine(engine: DebugEngine, preset: DebugPreset)
    case modelLoadFailed
    case resampleFailed
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "Invalid value '\(value)' for \(flag)"
        case .invalidInputPath(let path):
            return "Input path does not exist or is unsupported: \(path)"
        case .invalidPresetForEngine(let engine, let preset):
            return "Preset '\(preset.rawValue)' is not valid for engine '\(engine.rawValue)'"
        case .modelLoadFailed:
            return "Failed to load Whisper model"
        case .resampleFailed:
            return "Failed to resample audio to 16kHz"
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with status \(code)"
        }
    }
}

private enum DebugEngine: String {
    case whisper
    case parakeet
}

private enum DebugPreset: String {
    case currentApp = "current-app"
    case candidateFix = "candidate-fix"
    case nanovoxLike = "nanovox-like"
    case `default`
}

private enum WhisperLanguageMode: Sendable {
    case auto
    case fixed(String)
}

private struct WhisperTranscriptionOptions: Sendable {
    var language: WhisperLanguageMode
    var detectLanguage: Bool
    var noTimestamps: Bool
    var singleSegment: Bool
    var tokenTimestamps: Bool
    var splitOnWord: Bool
    var maxLen: Int32
    var noContext: Bool
    var temperature: Float
    var threadCount: Int32

    static func appDefault() -> WhisperTranscriptionOptions {
        WhisperTranscriptionOptions(
            language: .fixed("en"),
            detectLanguage: false,
            noTimestamps: true,
            singleSegment: false,
            tokenTimestamps: false,
            splitOnWord: false,
            maxLen: 0,
            noContext: true,
            temperature: 0.0,
            threadCount: max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        )
    }

    static func candidateFixDefault() -> WhisperTranscriptionOptions {
        WhisperTranscriptionOptions(
            language: .fixed("en"),
            detectLanguage: false,
            noTimestamps: false,
            singleSegment: false,
            tokenTimestamps: false,
            splitOnWord: false,
            maxLen: 0,
            noContext: false,
            temperature: 0.0,
            threadCount: max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        )
    }

    static func nanoVoxLike() -> WhisperTranscriptionOptions {
        WhisperTranscriptionOptions(
            language: .fixed("en"),
            detectLanguage: false,
            noTimestamps: false,
            singleSegment: false,
            tokenTimestamps: true,
            splitOnWord: false,
            maxLen: 1,
            noContext: false,
            temperature: 0.0,
            threadCount: max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        )
    }
}

private struct ParsedArgs {
    let inputPath: String
    let engine: DebugEngine
    let preset: DebugPreset
    let outputDir: URL?
    let noTimestamps: Bool?
    let tokenTimestamps: Bool?
    let splitOnWord: Bool?
    let maxLen: Int32?
    let detectLanguage: Bool?
    let singleSegment: Bool?
    let language: WhisperLanguageMode?
}

private struct ResolvedInput {
    let sourceURL: URL
    let audioURL: URL
    let sourceKind: String
}

private struct SegmentArtifact: Codable {
    let totalDuration: TimeInterval
    let wordTimestampsEnabled: Bool
    let segments: [TranscriptionSegment]
}

private struct DebugRunArtifact: Codable {
    let createdAt: Date
    let engine: String
    let preset: String
    let sourcePath: String
    let sourceKind: String
    let audioPath: String
    let outputDir: String
    let overrides: [String: String]
    let model: String
}

private struct DebugMetadataArtifact: Codable {
    struct RecordingInfo: Codable {
        let duration: TimeInterval
        let sampleRate: Double
        let channels: Int
        let fileSize: Int64
        let inputDevice: String?
    }

    struct TranscriptionInfo: Codable {
        let text: String
        let language: String
        let transcriptionDuration: TimeInterval
        let segments: [TranscriptionSegment]
        let model: String
    }

    struct Configuration: Codable {
        let voiceModel: String
        let language: String
    }

    let id: String
    let createdAt: Date
    let recording: RecordingInfo
    let transcription: TranscriptionInfo
    let configuration: Configuration
}

private final class AudioBufferInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct WhisperDecodeResult: Sendable {
    let text: String
    let language: String
    let segments: [TranscriptionSegment]
}

private final class WhisperContext {
    private let ctx: OpaquePointer

    private init(ctx: OpaquePointer) {
        self.ctx = ctx
    }

    static func load(from path: String) throws -> WhisperContext {
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(path, contextParams) else {
            throw CLIError.modelLoadFailed
        }

        return WhisperContext(ctx: ctx)
    }

    func transcribe(samples: [Float], options: WhisperTranscriptionOptions, vadModelPath: String?) throws -> WhisperDecodeResult {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        var languageCString: UnsafeMutablePointer<CChar>?
        switch options.language {
        case .auto:
            params.language = nil
        case .fixed(let language):
            languageCString = strdup(language)
            params.language = UnsafePointer(languageCString)
        }
        defer {
            if let languageCString {
                free(languageCString)
            }
        }

        params.detect_language = options.detectLanguage
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = options.noTimestamps
        params.single_segment = options.singleSegment
        params.no_context = options.noContext
        params.temperature = options.temperature
        params.token_timestamps = options.tokenTimestamps
        params.split_on_word = options.splitOnWord
        params.max_len = options.maxLen
        params.n_threads = options.threadCount

        if let vadPath = vadModelPath {
            params.vad = true
            params.vad_model_path = (vadPath as NSString).utf8String
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.5
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        }

        let resultCode = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(ptr.count))
        }

        guard resultCode == 0 else {
            throw CLIError.transcriptionFailed(resultCode)
        }

        let segmentCount = whisper_full_n_segments(ctx)
        var text = ""
        var segments: [TranscriptionSegment] = []

        for i in 0..<segmentCount {
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let segmentText = String(cString: cText)
            text += segmentText
            let start = max(0, Double(whisper_full_get_segment_t0(ctx, i)) / 100.0)
            let end = max(start, Double(whisper_full_get_segment_t1(ctx, i)) / 100.0)
            segments.append(TranscriptionSegment(start: start, end: end, text: segmentText, words: nil))
        }

        let langID = whisper_full_lang_id(ctx)
        let language = whisper_lang_str(langID).map { String(cString: $0) } ?? "en"

        return WhisperDecodeResult(text: text, language: language, segments: segments)
    }

    deinit {
        whisper_free(ctx)
    }
}

@MainActor
private final class WhisperEngine {
    private var context: WhisperContext?
    private var initTask: Task<Void, Error>?

    private static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    private static let vadModelFileName = "ggml-silero-v5.1.2.bin"
    private static let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MiniWhisper/models")
    }

    static var modelPath: URL {
        modelsDirectory.appendingPathComponent(modelFileName)
    }

    static var vadModelPath: URL {
        modelsDirectory.appendingPathComponent(vadModelFileName)
    }

    func initialize() async throws {
        if context != nil { return }

        if let task = initTask {
            try await task.value
            return
        }

        let task = Task<Void, Error> {
            try await Self.ensureModelExists()
            try await Self.ensureVADModelExists()
            context = try WhisperContext.load(from: Self.modelPath.path)
        }
        initTask = task

        do {
            try await task.value
        } catch {
            initTask = nil
            throw error
        }
    }

    func transcribe(audioURL: URL, options: WhisperTranscriptionOptions) async throws -> TranscriptionResult {
        if context == nil {
            try await initialize()
        }

        guard let context else {
            throw CLIError.modelLoadFailed
        }

        let samples = try resampleTo16kHz(audioURL: audioURL)
        let audioDuration = Double(samples.count) / 16_000.0

        let vadPath: String? = FileManager.default.fileExists(atPath: Self.vadModelPath.path) ? Self.vadModelPath.path : nil
        let decode = try context.transcribe(samples: samples, options: options, vadModelPath: vadPath)
        let trimmed = decode.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        var segments = decode.segments
        if segments.isEmpty && !trimmed.isEmpty {
            segments = [TranscriptionSegment(start: 0, end: audioDuration, text: trimmed, words: nil)]
        }

        return TranscriptionResult(
            text: trimmed,
            segments: segments,
            language: decode.language,
            duration: segments.last?.end ?? audioDuration,
            model: "whisper-large-v3-turbo"
        )
    }

    private static func ensureModelExists() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: modelPath.path) {
            return
        }

        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let (downloadedURL, response) = try await URLSession.shared.download(from: modelURL)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw CLIError.modelLoadFailed
        }

        let temporary = modelPath.appendingPathExtension("download")
        try? fm.removeItem(at: temporary)
        if fm.fileExists(atPath: modelPath.path) {
            return
        }
        try fm.moveItem(at: downloadedURL, to: temporary)
        try fm.moveItem(at: temporary, to: modelPath)
    }

    private static func ensureVADModelExists() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: vadModelPath.path) {
            return
        }

        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let (downloadedURL, response) = try await URLSession.shared.download(from: vadModelURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CLIError.modelLoadFailed
        }

        if fm.fileExists(atPath: vadModelPath.path) {
            return
        }
        try fm.moveItem(at: downloadedURL, to: vadModelPath)
    }

    private func resampleTo16kHz(audioURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: audioURL)

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioFile.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CLIError.resampleFailed
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw CLIError.resampleFailed
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw CLIError.resampleFailed
        }

        if audioFile.fileFormat.channelCount != 1 || audioFile.fileFormat.commonFormat != .pcmFormatFloat32 {
            guard let converter = AVAudioConverter(from: audioFile.fileFormat, to: inputFormat) else {
                throw CLIError.resampleFailed
            }
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.fileFormat, frameCapacity: frameCount) else {
                throw CLIError.resampleFailed
            }

            try audioFile.read(into: readBuffer)
            inputBuffer.frameLength = frameCount

            let state = AudioBufferInputState(buffer: readBuffer)
            var conversionError: NSError?
            converter.convert(to: inputBuffer, error: &conversionError) { _, outStatus in
                if state.consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                state.consumed = true
                outStatus.pointee = .haveData
                return state.buffer
            }
            if let conversionError {
                throw conversionError
            }
        } else {
            try audioFile.read(into: inputBuffer)
        }

        if audioFile.fileFormat.sampleRate == 16000 {
            guard let ptr = inputBuffer.floatChannelData?[0] else {
                throw CLIError.resampleFailed
            }
            return Array(UnsafeBufferPointer(start: ptr, count: Int(inputBuffer.frameLength)))
        }

        guard let resampler = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CLIError.resampleFailed
        }

        let ratio = 16000.0 / audioFile.fileFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw CLIError.resampleFailed
        }

        let state = AudioBufferInputState(buffer: inputBuffer)
        var resampleError: NSError?
        resampler.convert(to: outputBuffer, error: &resampleError) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        if let resampleError {
            throw resampleError
        }

        guard let ptr = outputBuffer.floatChannelData?[0] else {
            throw CLIError.resampleFailed
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength)))
    }
}

@MainActor
private final class ParakeetEngine {
    private var asrManager: AsrManager?
    private var initTask: Task<Void, Error>?

    func initialize() async throws {
        if asrManager != nil { return }

        if let task = initTask {
            try await task.value
            return
        }

        let task = Task<Void, Error> {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            asrManager = manager
        }
        initTask = task

        do {
            try await task.value
        } catch {
            initTask = nil
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        if asrManager == nil {
            try await initialize()
        }

        guard let manager = asrManager else {
            throw CLIError.modelLoadFailed
        }

        let result = try await manager.transcribe(audioURL, source: .microphone)
        let segments = convertToSegments(result)

        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            segments: segments,
            language: "en",
            duration: segments.last?.end ?? result.duration,
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
        var confidences: [Float] = []

        for timing in tokenTimings {
            let token = timing.token
            let startsNewWord = token.hasPrefix(" ") || token.hasPrefix("▁") || (words.isEmpty && currentWord.isEmpty)

            if startsNewWord && !currentWord.isEmpty {
                let average = confidences.isEmpty ? 1.0 : confidences.reduce(0, +) / Float(confidences.count)
                words.append(WordTiming(word: currentWord, start: wordStart, end: wordEnd, probability: average))
                currentWord = ""
                confidences = []
            }

            let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: " ▁"))
            if currentWord.isEmpty {
                wordStart = timing.startTime
            }
            currentWord += clean
            wordEnd = timing.endTime
            confidences.append(timing.confidence)
        }

        if !currentWord.isEmpty {
            let average = confidences.isEmpty ? 1.0 : confidences.reduce(0, +) / Float(confidences.count)
            words.append(WordTiming(word: currentWord, start: wordStart, end: wordEnd, probability: average))
        }

        if words.isEmpty {
            return []
        }

        return [TranscriptionSegment(
            start: words.first?.start ?? 0,
            end: words.last?.end ?? result.duration,
            text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            words: words
        )]
    }
}

@main
struct MiniWhisperDebugCLI {
    static func main() async {
        do {
            let parsed = try parseArgs(Array(CommandLine.arguments.dropFirst()))
            let resolvedInput = try resolveInput(parsed.inputPath)
            let outputDir = parsed.outputDir ?? defaultOutputDir(
                input: resolvedInput,
                engine: parsed.engine,
                preset: parsed.preset
            )

            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let transcription = try await runTranscription(parsed: parsed, input: resolvedInput)
            let audioInfo = try loadAudioInfo(audioURL: resolvedInput.audioURL)

            try writeArtifacts(
                outputDir: outputDir,
                input: resolvedInput,
                transcription: transcription,
                audioInfo: audioInfo,
                parsed: parsed
            )

            print("transcription complete")
            print("engine: \(parsed.engine.rawValue)")
            print("preset: \(parsed.preset.rawValue)")
            print("audio: \(resolvedInput.audioURL.path)")
            print("output: \(outputDir.path)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func parseArgs(_ args: [String]) throws -> ParsedArgs {
        guard args.first == "transcribe" else {
            throw CLIError.usage(usageText)
        }

        var inputPath: String?
        var engine: DebugEngine = .whisper
        var preset: DebugPreset?
        var outputDir: URL?
        var noTimestamps: Bool?
        var tokenTimestamps: Bool?
        var splitOnWord: Bool?
        var maxLen: Int32?
        var detectLanguage: Bool?
        var singleSegment: Bool?
        var language: WhisperLanguageMode?

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                switch arg {
                case "--engine":
                    let value = try parseStringValue(args, at: &index, flag: arg)
                    guard let parsed = DebugEngine(rawValue: value) else {
                        throw CLIError.invalidValue(flag: arg, value: value)
                    }
                    engine = parsed
                case "--preset":
                    let value = try parseStringValue(args, at: &index, flag: arg)
                    guard let parsed = DebugPreset(rawValue: value) else {
                        throw CLIError.invalidValue(flag: arg, value: value)
                    }
                    preset = parsed
                case "--output-dir":
                    let value = try parseStringValue(args, at: &index, flag: arg)
                    outputDir = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--no-timestamps":
                    noTimestamps = try parseBoolValue(args, at: &index, flag: arg)
                case "--token-timestamps":
                    tokenTimestamps = try parseBoolValue(args, at: &index, flag: arg)
                case "--split-on-word":
                    splitOnWord = try parseBoolValue(args, at: &index, flag: arg)
                case "--max-len":
                    let value = try parseStringValue(args, at: &index, flag: arg)
                    guard let parsed = Int32(value) else {
                        throw CLIError.invalidValue(flag: arg, value: value)
                    }
                    maxLen = parsed
                case "--detect-language":
                    detectLanguage = try parseBoolValue(args, at: &index, flag: arg)
                case "--single-segment":
                    singleSegment = try parseBoolValue(args, at: &index, flag: arg)
                case "--language":
                    let value = try parseStringValue(args, at: &index, flag: arg)
                    if value == "auto" {
                        language = .auto
                    } else {
                        language = .fixed(value)
                    }
                case "--help":
                    throw CLIError.usage(usageText)
                default:
                    throw CLIError.invalidValue(flag: "flag", value: arg)
                }
            } else if inputPath == nil {
                inputPath = arg
            } else {
                throw CLIError.usage(usageText)
            }
            index += 1
        }

        guard let inputPath else {
            throw CLIError.usage(usageText)
        }

        let effectivePreset = preset ?? (engine == .whisper ? .currentApp : .default)
        if engine == .parakeet && effectivePreset != .default {
            throw CLIError.invalidPresetForEngine(engine: engine, preset: effectivePreset)
        }

        return ParsedArgs(
            inputPath: inputPath,
            engine: engine,
            preset: effectivePreset,
            outputDir: outputDir,
            noTimestamps: noTimestamps,
            tokenTimestamps: tokenTimestamps,
            splitOnWord: splitOnWord,
            maxLen: maxLen,
            detectLanguage: detectLanguage,
            singleSegment: singleSegment,
            language: language
        )
    }

    private static func parseStringValue(_ args: [String], at index: inout Int, flag: String) throws -> String {
        let next = index + 1
        guard next < args.count else {
            throw CLIError.missingValue(flag)
        }
        index = next
        return args[next]
    }

    private static func parseBoolValue(_ args: [String], at index: inout Int, flag: String) throws -> Bool {
        let value = try parseStringValue(args, at: &index, flag: flag).lowercased()
        switch value {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            throw CLIError.invalidValue(flag: flag, value: value)
        }
    }

    private static func resolveInput(_ rawPath: String) throws -> ResolvedInput {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw CLIError.invalidInputPath(rawPath)
        }

        if isDirectory.boolValue {
            let audioURL = path.appendingPathComponent("audio.wav")
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw CLIError.invalidInputPath(rawPath)
            }
            return ResolvedInput(sourceURL: path, audioURL: audioURL, sourceKind: "recording_directory")
        }

        return ResolvedInput(sourceURL: path, audioURL: path, sourceKind: "audio_file")
    }

    private static func defaultOutputDir(input: ResolvedInput, engine: DebugEngine, preset: DebugPreset) -> URL {
        let baseDir: URL
        if input.sourceKind == "recording_directory" {
            baseDir = input.sourceURL.appendingPathComponent("debug-runs", isDirectory: true)
        } else {
            baseDir = input.sourceURL.deletingLastPathComponent().appendingPathComponent("debug-runs", isDirectory: true)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return baseDir.appendingPathComponent("\(stamp)-\(engine.rawValue)-\(preset.rawValue)", isDirectory: true)
    }

    @MainActor
    private static func runTranscription(parsed: ParsedArgs, input: ResolvedInput) async throws -> TranscriptionResult {
        switch parsed.engine {
        case .parakeet:
            let engine = ParakeetEngine()
            return try await engine.transcribe(audioURL: input.audioURL)
        case .whisper:
            let engine = WhisperEngine()
            var options = whisperOptions(for: parsed.preset)
            if let noTimestamps = parsed.noTimestamps {
                options.noTimestamps = noTimestamps
            }
            if let tokenTimestamps = parsed.tokenTimestamps {
                options.tokenTimestamps = tokenTimestamps
            }
            if let splitOnWord = parsed.splitOnWord {
                options.splitOnWord = splitOnWord
            }
            if let maxLen = parsed.maxLen {
                options.maxLen = maxLen
            }
            if let detectLanguage = parsed.detectLanguage {
                options.detectLanguage = detectLanguage
            }
            if let singleSegment = parsed.singleSegment {
                options.singleSegment = singleSegment
            }
            if let language = parsed.language {
                options.language = language
            }
            return try await engine.transcribe(audioURL: input.audioURL, options: options)
        }
    }

    private static func whisperOptions(for preset: DebugPreset) -> WhisperTranscriptionOptions {
        switch preset {
        case .currentApp:
            return .appDefault()
        case .candidateFix:
            return .candidateFixDefault()
        case .nanovoxLike:
            return .nanoVoxLike()
        case .default:
            return .appDefault()
        }
    }

    private static func loadAudioInfo(audioURL: URL) throws -> (duration: TimeInterval, sampleRate: Double, channels: Int, fileSize: Int64) {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let channels = Int(audioFile.fileFormat.channelCount)
        let sampleRate = audioFile.fileFormat.sampleRate
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        return (duration, sampleRate, channels, fileSize)
    }

    private static func writeArtifacts(
        outputDir: URL,
        input: ResolvedInput,
        transcription: TranscriptionResult,
        audioInfo: (duration: TimeInterval, sampleRate: Double, channels: Int, fileSize: Int64),
        parsed: ParsedArgs
    ) throws {
        try transcription.text.write(to: outputDir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let segments = SegmentArtifact(
            totalDuration: audioInfo.duration,
            wordTimestampsEnabled: transcription.segments.contains { $0.words?.isEmpty == false },
            segments: transcription.segments
        )
        try writeJSON(segments, to: outputDir.appendingPathComponent("segments.json"))

        let recordingID = String(Int(Date().timeIntervalSince1970 * 1000))
        let metadata = DebugMetadataArtifact(
            id: recordingID,
            createdAt: Date(),
            recording: .init(
                duration: audioInfo.duration,
                sampleRate: audioInfo.sampleRate,
                channels: audioInfo.channels,
                fileSize: audioInfo.fileSize,
                inputDevice: nil
            ),
            transcription: .init(
                text: transcription.text,
                language: transcription.language,
                transcriptionDuration: transcription.duration,
                segments: transcription.segments,
                model: transcription.model
            ),
            configuration: .init(
                voiceModel: transcription.model,
                language: transcription.language
            )
        )
        try writeJSON(metadata, to: outputDir.appendingPathComponent("metadata.json"))

        var overrides: [String: String] = [:]
        if let value = parsed.noTimestamps { overrides["no_timestamps"] = String(value) }
        if let value = parsed.tokenTimestamps { overrides["token_timestamps"] = String(value) }
        if let value = parsed.splitOnWord { overrides["split_on_word"] = String(value) }
        if let value = parsed.maxLen { overrides["max_len"] = String(value) }
        if let value = parsed.detectLanguage { overrides["detect_language"] = String(value) }
        if let value = parsed.singleSegment { overrides["single_segment"] = String(value) }
        if let value = parsed.language {
            switch value {
            case .auto:
                overrides["language"] = "auto"
            case .fixed(let language):
                overrides["language"] = language
            }
        }

        let run = DebugRunArtifact(
            createdAt: Date(),
            engine: parsed.engine.rawValue,
            preset: parsed.preset.rawValue,
            sourcePath: input.sourceURL.path,
            sourceKind: input.sourceKind,
            audioPath: input.audioURL.path,
            outputDir: outputDir.path,
            overrides: overrides,
            model: transcription.model
        )
        try writeJSON(run, to: outputDir.appendingPathComponent("debug-run.json"))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url)
    }

    private static var usageText: String {
        """
        Usage:
          MiniWhisperDebug transcribe <input-path> [options]

        Input:
          <input-path>                 Audio file path or MiniWhisper recording directory containing audio.wav

        Options:
          --engine whisper|parakeet    Transcription engine (default: whisper)
          --preset current-app|candidate-fix|nanovox-like|default
                                       Whisper preset (default: current-app for whisper, default for parakeet)
          --output-dir <path>          Output directory for transcript and JSON artifacts
          --language auto|<lang>       Whisper language override
          --no-timestamps <bool>       Whisper no_timestamps override
          --token-timestamps <bool>    Whisper token_timestamps override
          --split-on-word <bool>       Whisper split_on_word override
          --max-len <int>              Whisper max_len override
          --detect-language <bool>     Whisper detect_language override
          --single-segment <bool>      Whisper single_segment override
          --help                       Show this message
        """
    }
}
