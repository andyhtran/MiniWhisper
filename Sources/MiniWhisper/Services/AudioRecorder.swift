import AVFoundation
import CoreAudio
import os

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

/// Thread-safe bridge for passing RMS meter values from CoreAudio's real-time
/// callback thread to the MainActor-isolated AudioRecorder. Uses atomic-style
/// access through os_unfair_lock so the audio thread never blocks.
final class MeterBridge: Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: Float(0))

    func store(_ value: Float) {
        _lock.withLock { $0 = value }
    }

    func load() -> Float {
        _lock.withLock { $0 }
    }
}

@MainActor
@Observable
final class AudioRecorder: Sendable {
    var state: RecordingState = .idle
    var currentDuration: TimeInterval = 0
    var actualSampleRate: Double = 44100
    /// Normalized microphone level (0...1) for menu bar meter display.
    /// Updated ~10-12 Hz while recording; resets to 0 when not recording.
    var meterLevel: Double = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private let meterBridge = MeterBridge()
    /// Smoothed dBFS value retained between timer ticks for asymmetric smoothing
    private var smoothedDB: Float = -60

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
        // Routed devices need inputFormat — outputFormat still reflects the
        // system default's format even after CurrentDevice binding.
        let inputFormat: AVAudioFormat
        if deviceID != nil {
            inputFormat = inputNode.inputFormat(forBus: 0)
        } else {
            inputFormat = inputNode.outputFormat(forBus: 0)
        }

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

        // Verify device routing survived engine.start() — some configurations
        // reset the binding during startup (observed with Bluetooth devices).
        if let deviceID {
            var currentDeviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(
                engine.inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDeviceID,
                &size
            )
            if currentDeviceID != deviceID {
                print("[AudioRecorder] Warning: device routing reset after start (expected \(deviceID), got \(currentDeviceID))")
            }
        }

        audioEngine = engine
        audioFile = file
        recordingURL = url
        recordingStartTime = Date()
        state = .recording

        // ~10 Hz timer for both duration display and meter level updates.
        // Polling the meter bridge here instead of dispatching from the audio
        // callback avoids flooding SwiftUI with per-buffer updates (~40-50/sec).
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.currentDuration = Date().timeIntervalSince(start)
                self.updateMeterLevel()
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
        let bridge = meterBridge

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            // Float32 path (standard)
            if let channelData = buffer.floatChannelData {
                // Compute RMS from channel 0 for the meter bridge
                var sumOfSquares: Float = 0
                let ch0 = channelData[0]
                for i in 0..<frameLength {
                    sumOfSquares += ch0[i] * ch0[i]
                }
                let rms = sqrtf(sumOfSquares / Float(frameLength))
                bridge.store(rms)

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
                return
            }

            // Int16 path — some USB microphones deliver int16ChannelData
            if let int16Data = buffer.int16ChannelData {
                guard let monoBuffer = AVAudioPCMBuffer(
                    pcmFormat: wavFormat,
                    frameCapacity: buffer.frameCapacity
                ) else { return }
                monoBuffer.frameLength = buffer.frameLength

                if let monoData = monoBuffer.floatChannelData {
                    let int16Buffer = UnsafeBufferPointer(start: int16Data[0], count: frameLength)
                    for i in 0..<frameLength {
                        monoData[0][i] = Float(int16Buffer[i]) / Float(Int16.max)
                    }
                }

                // Compute RMS from the converted float samples
                if let monoData = monoBuffer.floatChannelData {
                    var sumOfSquares: Float = 0
                    for i in 0..<frameLength {
                        sumOfSquares += monoData[0][i] * monoData[0][i]
                    }
                    bridge.store(sqrtf(sumOfSquares / Float(frameLength)))
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

    // MARK: - Meter

    /// Reads the latest RMS from the audio thread bridge, converts to dBFS,
    /// applies a noise gate and asymmetric smoothing, then normalizes to 0...1.
    private func updateMeterLevel() {
        let rms = meterBridge.load()
        let db = AudioRecorder.rmsToDBFS(rms)

        // Asymmetric smoothing: rise fast so speech feels responsive,
        // fall slow so bars don't flicker between words.
        let alpha: Float = db > smoothedDB ? 0.6 : 0.15
        smoothedDB += alpha * (db - smoothedDB)

        meterLevel = AudioRecorder.normalizeMeter(dbFS: smoothedDB)
    }

    /// Convert linear RMS amplitude to dBFS. Clamps silence to -60 dB
    /// to avoid -inf from log10(0).
    nonisolated static func rmsToDBFS(_ rms: Float) -> Float {
        guard rms > 0 else { return -60 }
        return max(20 * log10f(rms), -60)
    }

    /// Map dBFS into 0...1 with a noise gate. Anything below the gate
    /// (about -42 dBFS, typical room/fan noise floor) maps to 0.
    /// Speech range roughly -42 to -12 dBFS maps linearly to 0...1.
    nonisolated static func normalizeMeter(dbFS: Float) -> Double {
        let gate: Float = -42
        let ceiling: Float = -12
        guard dbFS > gate else { return 0 }
        let normalized = (dbFS - gate) / (ceiling - gate)
        return Double(min(max(normalized, 0), 1))
    }

    func stopRecording() -> URL? {
        guard state.isRecording else { return nil }

        tearDownEngine()
        let url = recordingURL
        recordingURL = nil
        recordingStartTime = nil
        meterLevel = 0
        smoothedDB = -60

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
        meterLevel = 0
        smoothedDB = -60

        state = .idle
    }

    private func tearDownEngine() {
        durationTimer?.invalidate()
        durationTimer = nil
        let engine = audioEngine
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()  // CoreAudio synchronization barrier
        audioEngine = nil
        audioFile = nil

        // Keep engine alive briefly so CoreAudio can drain in-flight callbacks
        if let engine {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                withExtendedLifetime(engine) {}
            }
        }
    }

    func reset() {
        currentDuration = 0
        meterLevel = 0
        smoothedDB = -60

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
