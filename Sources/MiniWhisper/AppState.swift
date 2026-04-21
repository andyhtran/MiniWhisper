import AppKit
import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class AppState: Sendable {
    let recorder = AudioRecorder()
    let deviceManager = AudioDeviceManager()
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

    var warningShown = false
    var durationCheckTimer: Timer?
    var currentRecordingId: String?
    var captureTransitionInFlight = false

    var onRecordingStarted: (() -> Void)?
    var onRecordingEnded: (() -> Void)?

    var isModelLoaded: Bool {
        switch transcriptionMode {
        case .default: return parakeet.isInitialized
        case .multilingual: return whisper.isInitialized
        case .custom: return customProviderSettings.isConfigured
        }
    }

    var isModelDownloading: Bool { whisper.isDownloading }
    var modelDownloadProgress: Double { whisper.downloadProgress }

    init() {
        recorder.onRecordingInterrupted = { [weak self] message in
            guard let self else { return }
            stopDurationChecks()
            onRecordingEnded?()
            currentRecordingId = nil
            captureTransitionInFlight = false
            toast.showError(title: "Recording Failed", message: message)
            recorder.reset()
        }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appState = Unmanaged<AppState>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    appState.replacementSettings = ReplacementSettings.load()
                }
            },
            "com.miniwhisper.config-changed" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Initialization

    func preloadModel() {
        Task {
            do {
                switch transcriptionMode {
                case .default:
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
            toast.showError(
                title: "Cannot Switch", message: "Stop recording before switching models.")
            return
        }

        if recorder.state == .processing {
            return
        }

        switch transcriptionMode {
        case .default: parakeet.unload()
        case .multilingual: whisper.unload()
        case .custom: break
        }

        transcriptionMode = mode
        TranscriptionModeStorage.save(mode)

        Task {
            do {
                switch mode {
                case .default:
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
        Task { await startRecordingFlow() }
    }

    func stopAndTranscribe() {
        Task { await stopAndTranscribeFlow() }
    }

    func cancelRecording() {
        Task { await cancelRecordingFlow() }
    }

    func retranscribe(_ recording: Recording) {
        guard recorder.state.isIdle else {
            toast.showError(
                title: "Busy", message: "Wait for the current recording/transcription to finish.")
            return
        }
        guard recording.canRetranscribe else {
            toast.showError(
                title: "Cannot Re-transcribe", message: "Audio file is no longer available.")
            return
        }

        recorder.state = .processing

        Task {
            await retranscribeCancelledRecording(recording)
        }
    }

    /// Re-transcribe a completed recording with the currently active model,
    /// creating a new history entry. Does not auto-paste — the user copies
    /// from the new history row manually.
    func retranscribeAsNew(_ recording: Recording) {
        guard recorder.state.isIdle else {
            toast.showError(
                title: "Busy", message: "Wait for the current recording/transcription to finish.")
            return
        }
        guard recording.canRetranscribeAsNew else {
            toast.showError(
                title: "Cannot Re-transcribe", message: "Audio file is no longer available.")
            return
        }

        recorder.state = .processing

        Task {
            await retranscribeAsNewEntry(from: recording)
        }
    }

    // MARK: - Shortcuts

    func reloadShortcuts() {
        CustomShortcutMonitor.shared.reloadShortcuts()
    }

}
