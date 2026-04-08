import AVFoundation
import CoreAudio

enum RecordingState: Equatable, Sendable {
    case idle
    case recording
    case processing
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        if case .error = self { return true }
        return false
    }
}

@MainActor
@Observable
final class AudioRecorder: Sendable {
    var state: RecordingState = .idle
    var currentDuration: TimeInterval = 0
    var actualSampleRate: Double = 44100

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    /// Start recording to the given URL, optionally binding a specific input device.
    /// When deviceID is nil, AVAudioEngine uses the system default input device.
    /// When deviceID is provided, the engine's input node is bound to that specific
    /// device before any format queries, so recording captures from the chosen mic
    /// without changing the macOS system default.
    func startRecording(to url: URL, deviceID: AudioDeviceID? = nil) throws {
        guard state.isIdle else { return }

        let engine = AVAudioEngine()

        // Bind a specific input device before accessing the input node's format.
        // This must happen before outputFormat(forBus:) because that call causes
        // the engine to configure itself against whatever device is currently set.
        if let deviceID {
            let inputNode = engine.inputNode
            guard let audioUnit = inputNode.audioUnit else {
                throw RecordingError.deviceBindingFailed
            }
            var devID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw RecordingError.deviceBindingFailed
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.noInputAvailable
        }

        actualSampleRate = inputFormat.sampleRate

        // Create WAV file for recording (mono float32 at hardware sample rate)
        let wavFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: wavFormat.settings)

        // Install tap on input node using nonisolated closure for CoreAudio real-time thread
        let bufferSize: AVAudioFrameCount = 1024
        installInputTap(
            on: inputNode,
            bufferSize: bufferSize,
            format: inputFormat,
            wavFormat: wavFormat,
            file: file
        )

        // Start engine with retry for post-sleep hardware wake-up
        try startEngineWithRetry(engine)

        audioEngine = engine
        audioFile = file
        recordingURL = url
        recordingStartTime = Date()
        state = .recording

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.currentDuration = Date().timeIntervalSince(start)
            }
        }
    }

    /// Installs the audio tap in a nonisolated context to avoid MainActor isolation
    /// on CoreAudio's real-time thread
    private nonisolated func installInputTap(
        on inputNode: AVAudioInputNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        wavFormat: AVAudioFormat,
        file: AVAudioFile
    ) {
        let unsafeFile = file
        let channelCount = format.channelCount

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            if channelCount == 1 && format.commonFormat == .pcmFormatFloat32 {
                try? unsafeFile.write(from: buffer)
            } else {
                guard let monoBuffer = AVAudioPCMBuffer(
                    pcmFormat: wavFormat,
                    frameCapacity: buffer.frameCapacity
                ) else { return }
                monoBuffer.frameLength = buffer.frameLength

                if let monoData = monoBuffer.floatChannelData {
                    for i in 0..<frameLength {
                        var sample: Float = 0
                        for ch in 0..<Int(channelCount) {
                            sample += channelData[ch][i]
                        }
                        monoData[0][i] = sample / Float(channelCount)
                    }
                }
                try? unsafeFile.write(from: monoBuffer)
            }
        }
    }

    /// Start engine with retry logic for post-sleep hardware wake-up
    private func startEngineWithRetry(_ engine: AVAudioEngine) throws {
        let maxRetries = 5
        let retryDelay: UInt64 = 250_000_000  // 250ms

        for attempt in 0..<maxRetries {
            do {
                try engine.start()
                return
            } catch {
                if attempt < maxRetries - 1 {
                    // Brief delay to allow hardware to wake up
                    Thread.sleep(forTimeInterval: Double(retryDelay) / 1_000_000_000)
                } else {
                    throw error
                }
            }
        }
    }

    func stopRecording() -> URL? {
        guard state.isRecording else { return nil }

        tearDownEngine()
        let url = recordingURL
        recordingURL = nil
        recordingStartTime = nil


        state = .processing
        return url
    }

    func cancelRecording() {
        guard state.isRecording else { return }

        tearDownEngine()

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }

        recordingURL = nil
        recordingStartTime = nil
        currentDuration = 0

        state = .idle
    }

    private func tearDownEngine() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
    }

    func reset() {
        currentDuration = 0

        state = .idle
    }
}

enum RecordingError: LocalizedError {
    case noInputAvailable
    case deviceBindingFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No audio input device available"
        case .deviceBindingFailed: return "Failed to bind the selected microphone"
        }
    }
}
