import Foundation
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
    var actualInputDeviceName: String = "System Default"
    /// Normalized microphone level (0...1) for menu bar meter display.
    /// Updated ~10-12 Hz while recording; resets to 0 when not recording.
    var meterLevel: Double = 0
    var onRecordingInterrupted: ((String) -> Void)?

    private let hardwareQueue = DispatchQueue(label: "com.miniwhisper.audio.hardware", qos: .userInitiated)
    private var capture: CoreAudioInputCapture?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private let meterBridge = MeterBridge()
    /// Smoothed dBFS value retained between timer ticks for asymmetric smoothing
    private var smoothedDB: Float = -60
    private var transitionInFlight = false

    func startRecording(to url: URL, resolvedDevice: ResolvedRecordingDevice) async throws {
        guard state.isIdle else {
            throw RecordingError.busy
        }
        guard !transitionInFlight else {
            throw RecordingError.busy
        }
        guard resolvedDevice.deviceID != 0 else {
            throw RecordingError.noInputAvailable
        }
        transitionInFlight = true
        defer { transitionInFlight = false }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let capture = CoreAudioInputCapture(controlQueue: hardwareQueue)
        let bridge = meterBridge
        capture.onRMS = { rms in
            bridge.store(rms)
        }
        capture.onSessionFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleCaptureFailure(message: message)
            }
        }

        let sessionInfo: CaptureSessionInfo
        do {
            sessionInfo = try await runOnHardwareQueue {
                try capture.startRecording(toOutputFile: url, deviceID: resolvedDevice.deviceID)
            }
        } catch {
            await runOnHardwareQueue {
                capture.stopRecording()
            }
            throw error
        }

        self.capture = capture
        recordingURL = url
        recordingStartTime = Date()
        actualSampleRate = sessionInfo.sampleRate
        actualInputDeviceName = sessionInfo.deviceName
        state = .recording

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.currentDuration = Date().timeIntervalSince(start)
                self.updateMeterLevel()
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
    /// maps to 0. The wider range (-50 to -18) lets speech at arm's length
    /// register clearly while still filtering out most room ambience.
    nonisolated static func normalizeMeter(dbFS: Float) -> Double {
        let gate: Float = -50
        let ceiling: Float = -18
        guard dbFS > gate else { return 0 }
        let normalized = (dbFS - gate) / (ceiling - gate)
        return Double(min(max(normalized, 0), 1))
    }

    func stopRecording() async -> URL? {
        guard state.isRecording, !transitionInFlight else { return nil }
        transitionInFlight = true
        defer { transitionInFlight = false }

        await stopCaptureAndTimer()
        let url = recordingURL
        recordingURL = nil
        recordingStartTime = nil
        meterLevel = 0
        smoothedDB = -60

        state = .processing
        return url
    }

    func cancelRecording() async {
        guard state.isRecording, !transitionInFlight else { return }
        transitionInFlight = true
        defer { transitionInFlight = false }

        await stopCaptureAndTimer()

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

    private func handleCaptureFailure(message: String) {
        guard state.isRecording else { return }

        transitionInFlight = false

        let failedURL = recordingURL
        capture = nil
        durationTimer?.invalidate()
        durationTimer = nil
        recordingURL = nil
        recordingStartTime = nil
        currentDuration = 0
        meterLevel = 0
        smoothedDB = -60
        state = .error(message)

        if let url = failedURL {
            try? FileManager.default.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
        }

        onRecordingInterrupted?(message)
    }

    private func stopCaptureAndTimer() async {
        durationTimer?.invalidate()
        durationTimer = nil

        if let capture {
            await runOnHardwareQueue {
                capture.stopRecording()
            }
            self.capture = nil
        }
    }

    private func runOnHardwareQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            hardwareQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    private func runOnHardwareQueue<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            hardwareQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
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
    case busy

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No audio input device available"
        case .busy: return "Recorder is busy"
        }
    }
}
