import Foundation
import Observation
import AppKit
import UserNotifications

@Observable
@MainActor
final class AppState: Sendable {
    let recorder = AudioRecorder()
    let parakeet = ParakeetProvider()
    let whisper = WhisperProvider()
    let customProvider = CustomProvider()
    let recordingStore = RecordingStore()
    let analyticsStore = AnalyticsStore()
    let permissions = PermissionsManager()
    let pasteboard = PasteboardService()
    let toast = ToastWindowController.shared

    var replacementSettings = ReplacementSettings.load()
    var transcriptionMode: TranscriptionMode = TranscriptionModeStorage.load()
    var customProviderSettings = CustomProviderSettings.load()

    let maxRecordingDuration: TimeInterval = 600.0  // 10 minutes
    var warningDuration: TimeInterval { maxRecordingDuration * 0.8 }  // 8 minutes

    private var warningShown = false
    private var durationCheckTimer: Timer?
    private var currentRecordingId: String?

    var onRecordingStarted: (() -> Void)?
    var onRecordingEnded: (() -> Void)?

    var isModelLoaded: Bool {
        switch transcriptionMode {
        case .english: return parakeet.isInitialized
        case .multilingual: return whisper.isInitialized
        case .custom: return customProviderSettings.isConfigured
        }
    }

    var isModelDownloading: Bool { whisper.isDownloading }
    var modelDownloadProgress: Double { whisper.downloadProgress }

    // MARK: - Initialization

    func preloadModel() {
        Task {
            do {
                switch transcriptionMode {
                case .english:
                    try await parakeet.initialize()
                case .multilingual:
                    guard whisper.modelExists else { return }
                    try await whisper.initialize()
                case .custom:
                    break
                }
            } catch {
                toast.showError(title: "Model Load Failed", message: error.localizedDescription)
            }
        }
    }

    func switchTranscriptionMode(to mode: TranscriptionMode) {
        guard mode != transcriptionMode else { return }

        if recorder.state.isRecording {
            toast.showError(title: "Cannot Switch", message: "Stop recording before switching models.")
            return
        }

        if recorder.state == .processing {
            return
        }

        switch transcriptionMode {
        case .english: parakeet.unload()
        case .multilingual: whisper.unload()
        case .custom: break
        }

        transcriptionMode = mode
        TranscriptionModeStorage.save(mode)

        Task {
            do {
                switch mode {
                case .english:
                    try await parakeet.initialize()
                case .multilingual:
                    try await whisper.initialize()
                case .custom:
                    break
                }
            } catch {
                toast.showError(title: "Model Load Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard recorder.state.isIdle else { return }
        guard isModelLoaded else {
            if transcriptionMode == .custom {
                toast.showError(title: "Not Configured", message: "Configure your custom endpoint before recording.")
            } else {
                toast.showError(title: "Model Not Ready", message: "Please wait for the model to finish loading.")
            }
            return
        }

        let recordingId = Recording.generateId()
        currentRecordingId = recordingId
        warningShown = false

        let dir = Recording.baseDirectory.appendingPathComponent(recordingId)
        let audioURL = dir.appendingPathComponent("audio.wav")

        do {
            try recorder.startRecording(to: audioURL)
            startDurationChecks()
            onRecordingStarted?()
        } catch {
            toast.showError(title: "Recording Failed", message: error.localizedDescription)
            recorder.reset()
        }
    }

    func stopAndTranscribe() {
        guard recorder.state.isRecording else { return }

        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        guard duration >= 1.0 else {
            recorder.cancelRecording()
            return
        }

        guard let audioURL = recorder.stopRecording() else {
            recorder.reset()
            return
        }

        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        Task {
            await transcribe(audioURL: audioURL, recordingId: recordingId, duration: duration, sampleRate: sampleRate)
        }
    }

    func cancelRecording() {
        guard recorder.state.isRecording else { return }
        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        guard let audioURL = recorder.stopRecording() else {
            recorder.reset()
            return
        }
        recorder.reset()

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let recording = Recording(
            id: recordingId,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: duration,
                sampleRate: sampleRate,
                channels: 1,
                fileSize: fileSize,
                inputDevice: recorder.systemDefaultDeviceName
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: transcriptionMode.modelDisplayName,
                language: "en"
            ),
            status: .cancelled
        )

        do {
            try recordingStore.saveWithExistingAudio(recording)
        } catch {
            toast.showError(title: "Cancel Save Failed", message: error.localizedDescription)
        }
    }

    func retranscribe(_ recording: Recording) {
        guard recorder.state.isIdle else {
            toast.showError(title: "Busy", message: "Wait for the current recording/transcription to finish.")
            return
        }
        guard recording.canRetranscribe else {
            toast.showError(title: "Cannot Re-transcribe", message: "Audio file is no longer available.")
            return
        }

        recorder.state = .processing

        Task {
            await retranscribeCancelledRecording(recording)
        }
    }

    // MARK: - Transcription

    private func transcribe(audioURL: URL, recordingId: String, duration: TimeInterval, sampleRate: Double) async {
        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .english:
                result = try await parakeet.transcribe(audioURL: audioURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: audioURL)
            case .custom:
                result = try await customProvider.transcribe(audioURL: audioURL, settings: customProviderSettings)
            }

            // Guard against stale callback: if the user rapid-tapped and started a new
            // recording while transcription was in-flight, the state has moved on.
            // Applying this result would desync state from the active recording.
            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let finalText: String
            if replacementSettings.enabled {
                let processor = ReplacementProcessor(rules: replacementSettings.enabledRules)
                finalText = processor.apply(to: result.text)
            } else {
                finalText = result.text
            }

            pasteboard.copyAndPaste(finalText)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0

            let recording = Recording(
                id: recordingId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: duration,
                    sampleRate: sampleRate,
                    channels: 1,
                    fileSize: fileSize,
                    inputDevice: recorder.systemDefaultDeviceName
                ),
                transcription: RecordingTranscription(
                    text: finalText,
                    segments: result.segments,
                    language: result.language,
                    model: result.model,
                    transcriptionDuration: result.duration
                ),
                configuration: RecordingConfiguration(
                    voiceModel: result.model,
                    language: result.language
                ),
                status: .completed
            )

            try recordingStore.saveWithExistingAudio(recording)
            analyticsStore.record(
                duration: duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()

        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Transcription Failed", message: error.localizedDescription)

            // Save failed recording metadata (audio file may or may not exist)
            let recording = Recording(
                id: recordingId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: duration,
                    sampleRate: sampleRate,
                    channels: 1,
                    fileSize: 0,
                    inputDevice: recorder.systemDefaultDeviceName
                ),
                transcription: nil,
                configuration: RecordingConfiguration(
                    voiceModel: transcriptionMode.modelDisplayName,
                    language: "en"
                ),
                status: .failed
            )
            // Use saveMetadataOnly for failed recordings since audio may not exist
            try? recordingStore.saveFailedRecording(recording)
        }
    }

    private func retranscribeCancelledRecording(_ recording: Recording) async {
        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .english:
                result = try await parakeet.transcribe(audioURL: recording.audioURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: recording.audioURL)
            case .custom:
                result = try await customProvider.transcribe(audioURL: recording.audioURL, settings: customProviderSettings)
            }

            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let finalText: String
            if replacementSettings.enabled {
                let processor = ReplacementProcessor(rules: replacementSettings.enabledRules)
                finalText = processor.apply(to: result.text)
            } else {
                finalText = result.text
            }

            pasteboard.copyAndPaste(finalText)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.audioURL.path)[.size] as? Int64) ?? 0
            let updatedRecording = Recording(
                id: recording.id,
                createdAt: recording.createdAt,
                recording: RecordingInfo(
                    duration: recording.recording.duration,
                    sampleRate: recording.recording.sampleRate,
                    channels: recording.recording.channels,
                    fileSize: fileSize,
                    inputDevice: recording.recording.inputDevice
                ),
                transcription: RecordingTranscription(
                    text: finalText,
                    segments: result.segments,
                    language: result.language,
                    model: result.model,
                    transcriptionDuration: result.duration
                ),
                configuration: RecordingConfiguration(
                    voiceModel: result.model,
                    language: result.language
                ),
                status: .completed
            )

            try recordingStore.saveWithExistingAudio(updatedRecording)
            analyticsStore.record(
                duration: recording.recording.duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()
        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Re-transcription Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Duration Monitoring

    private func startDurationChecks() {
        durationCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDuration()
            }
        }
    }

    private func stopDurationChecks() {
        durationCheckTimer?.invalidate()
        durationCheckTimer = nil
    }

    private func checkDuration() {
        let duration = recorder.currentDuration

        if duration >= warningDuration && !warningShown {
            warningShown = true
            let remaining = Int(maxRecordingDuration - duration)
            toast.show(ToastMessage(
                type: .warning,
                title: "Recording Limit",
                message: "Recording will stop in \(remaining / 60) min \(remaining % 60) sec"
            ))

            let content = UNMutableNotificationContent()
            content.title = "Recording Limit"
            content.body = "Recording will automatically stop in ~2 minutes"
            let request = UNNotificationRequest(identifier: "recording-warning", content: content, trigger: nil)
            Task {
                try? await UNUserNotificationCenter.current().add(request)
            }
        }

        if duration >= maxRecordingDuration {
            stopAndTranscribe()
        }
    }

    // MARK: - Shortcuts

    func reloadShortcuts() {
        CustomShortcutMonitor.shared.reloadShortcuts()
    }

}
