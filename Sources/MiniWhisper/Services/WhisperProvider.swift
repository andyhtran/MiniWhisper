import Foundation
@preconcurrency import AVFoundation
import whisper

enum WhisperLanguageMode: Sendable {
    case auto
    case fixed(String)
}

struct WhisperTranscriptionOptions: Sendable {
    let language: WhisperLanguageMode
    let detectLanguage: Bool
    let noTimestamps: Bool
    let singleSegment: Bool
    let threadCount: Int32

    static func `default`() -> WhisperTranscriptionOptions {
        WhisperTranscriptionOptions(
            language: .fixed("en"),
            detectLanguage: false,
            noTimestamps: true,
            singleSegment: false,
            threadCount: max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        )
    }
}

private final class AudioBufferInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class WhisperContext: @unchecked Sendable {
    private let ctx: OpaquePointer
    private let vadModelPath: String?

    private init(ctx: OpaquePointer, vadModelPath: String?) {
        self.ctx = ctx
        self.vadModelPath = vadModelPath
    }

    static func load(from path: String, vadModelPath: String?) throws -> WhisperContext {
        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.modelLoadFailed
        }
        return WhisperContext(ctx: ctx, vadModelPath: vadModelPath)
    }

    static func transcriptionOptions() -> WhisperTranscriptionOptions {
        .default()
    }

    func transcribe(samples: [Float]) -> (text: String, language: String) {
        let options = Self.transcriptionOptions()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        var languageCString: UnsafeMutablePointer<CChar>?
        switch options.language {
        case .auto:
            params.language = nil
        case .fixed(let language):
            languageCString = strdup(language)
            params.language = languageCString.map { UnsafePointer($0) }
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
        params.no_context = true
        params.temperature = 0.0
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

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        guard result == 0 else {
            return ("", "en")
        }

        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cStr)
            }
        }

        let langId = whisper_full_lang_id(ctx)
        let language: String
        if let langStr = whisper_lang_str(langId) {
            language = String(cString: langStr)
        } else {
            language = "en"
        }

        return (text, language)
    }

    deinit {
        whisper_free(ctx)
    }
}

enum WhisperError: LocalizedError {
    case modelLoadFailed
    case transcriptionFailed
    case downloadFailed(String)
    case resampleFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load Whisper model"
        case .transcriptionFailed: return "Whisper transcription failed"
        case .downloadFailed(let reason): return "Model download failed: \(reason)"
        case .resampleFailed: return "Failed to resample audio to 16kHz"
        }
    }
}

@Observable
@MainActor
final class WhisperProvider: Sendable {
    private var context: WhisperContext?
    private var initTask: Task<Void, Error>?
    private var downloadTask: URLSessionDownloadTask?

    var isInitialized: Bool { context != nil }
    var isDownloading = false
    var downloadProgress: Double = 0.0

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

    var modelExists: Bool {
        FileManager.default.fileExists(atPath: Self.modelPath.path)
    }

    var vadModelExists: Bool {
        FileManager.default.fileExists(atPath: Self.vadModelPath.path)
    }

    func initialize() async throws {
        if context != nil { return }

        if let existing = initTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            if !modelExists {
                try await downloadModel()
            }
            if !vadModelExists {
                try await downloadVADModel()
            }

            let path = Self.modelPath.path
            let vadPath = Self.vadModelPath.path
            let loaded = try WhisperContext.load(from: path, vadModelPath: vadPath)
            context = loaded
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
        if context == nil {
            try await initialize()
        }

        guard let ctx = context else {
            throw WhisperError.modelLoadFailed
        }

        let startTime = Date()
        let samples = try resampleTo16kHz(audioURL: audioURL)
        let capturedCtx = ctx
        let result = await Task.detached {
            capturedCtx.transcribe(samples: samples)
        }.value
        let processingTime = Date().timeIntervalSince(startTime)

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionResult(
            text: trimmed,
            segments: [TranscriptionSegment(
                start: 0,
                end: processingTime,
                text: trimmed,
                words: nil
            )],
            language: result.language,
            duration: processingTime,
            model: "whisper-large-v3-turbo"
        )
    }

    func unload() {
        context = nil
        initTask = nil
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
        initTask = nil
    }

    private func downloadModel() async throws {
        let dir = Self.modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        isDownloading = true
        downloadProgress = 0.0

        defer {
            isDownloading = false
            downloadTask = nil
        }

        let delegate = WhisperDownloadDelegate()
        delegate.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: Self.modelURL)
        downloadTask = task

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.onComplete = { result in
                continuation.resume(with: result)
            }
            task.resume()
        }

        try FileManager.default.moveItem(at: tempURL, to: Self.modelPath)
        session.invalidateAndCancel()
    }

    private func downloadVADModel() async throws {
        let dir = Self.modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (downloadedURL, response) = try await URLSession.shared.download(from: Self.vadModelURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WhisperError.downloadFailed("VAD model download failed")
        }
        try FileManager.default.moveItem(at: downloadedURL, to: Self.vadModelPath)
    }

    private nonisolated func resampleTo16kHz(audioURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: audioURL)

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioFile.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperError.resampleFailed
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw WhisperError.resampleFailed
        }

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw WhisperError.resampleFailed
        }

        if audioFile.fileFormat.channelCount != 1 || audioFile.fileFormat.commonFormat != .pcmFormatFloat32 {
            guard let converter = AVAudioConverter(from: audioFile.fileFormat, to: inputFormat) else {
                throw WhisperError.resampleFailed
            }
            let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.fileFormat, frameCapacity: frameCount)!
            try audioFile.read(into: readBuffer)

            inputBuffer.frameLength = frameCount
            let inputState = AudioBufferInputState(buffer: readBuffer)
            var error: NSError?
            converter.convert(to: inputBuffer, error: &error) { _, outStatus in
                if inputState.consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputState.consumed = true
                outStatus.pointee = .haveData
                return inputState.buffer
            }
            if let error { throw error }
        } else {
            try audioFile.read(into: inputBuffer)
        }

        if audioFile.fileFormat.sampleRate == 16000 {
            let ptr = inputBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(inputBuffer.frameLength)))
        }

        guard let resampler = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw WhisperError.resampleFailed
        }

        let ratio = 16000.0 / audioFile.fileFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw WhisperError.resampleFailed
        }

        let inputState = AudioBufferInputState(buffer: inputBuffer)
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

        let ptr = outputBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength)))
    }
}

final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    nonisolated(unsafe) var onProgress: ((Double) -> Void)?
    nonisolated(unsafe) var onComplete: ((Result<URL, Error>) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            onComplete?(.success(tempFile))
        } catch {
            onComplete?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            onComplete?(.failure(error))
        }
    }
}
