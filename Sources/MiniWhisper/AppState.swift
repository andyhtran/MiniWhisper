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
    let editModeProvider = EditModeProvider()
    let customEditProvider = CustomEditProvider()
    let recordingStore = RecordingStore()
    let analyticsStore = AnalyticsStore()
    let permissions = PermissionsManager()
    let pasteboard = PasteboardService()
    let toast = ToastWindowController.shared

    var replacementSettings = ReplacementSettings.load()
    var transcriptionMode: TranscriptionMode = TranscriptionModeStorage.load()
    var customProviderSettings = CustomProviderSettings.load()
    var customEditProviderSettings = CustomEditProviderSettings.load()
    var editModeBehavior: EditModeBehavior = EditModeSettings.behavior

    var voiceEditEnabled: Bool { editModeBehavior.voiceEditEnabled }
    var autoCleanupEnabled: Bool { editModeBehavior.autoCleanupEnabled }

    /// Set while a voice-edit recording is active. Holds the captured
    /// selection + saved pasteboard so the second shortcut press can
    /// transcribe the voice instruction and apply it to the selection.
    /// When non-nil, the recorder is in `.recording` state but the
    /// normal toggle/cancel handlers route to the edit-mode flow
    /// instead of the standard transcribe-and-paste path.
    var editModeContext: EditModeContext?

    /// True when the active recording was started via the Auto-Cleanup
    /// shortcut. Read at transcription time to decide whether to run
    /// the LLM cleanup pass; reset on stop, cancel, and error.
    var cleanupRequestedForCurrentRecording: Bool = false

    /// True while the edit-mode flow is in its post-recording phase
    /// (transcribing the instruction + invoking the edit provider). Used
    /// by the menu bar icon + status text to render edit-specific state
    /// instead of the generic "Transcribing…" treatment.
    var isEditModeProcessing = false

    /// Character count of the current edit-mode selection. Used by the
    /// menu bar status text to surface scale for larger edits — only
    /// shown when above `EditModeProvider.softCharThreshold`.
    var editModeProcessingCharCount: Int = 0

    struct EditModeContext: Sendable {
        let selectedText: String
        let savedPasteboard: PasteboardService.SavedPasteboardContents?
        let recordingId: String
    }

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
            cleanupRequestedForCurrentRecording = false
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
        // Edit-mode recording uses the same recorder. Don't let the normal
        // toggle shortcut hijack it — the user has to press the edit
        // shortcut again (or Esc) to end an edit recording.
        if editModeContext != nil { return }

        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            cleanupRequestedForCurrentRecording = false
            startRecording()
        }
    }

    /// Auto-cleanup recording shortcut: starts/stops a normal recording
    /// but flags it so the LLM cleanup pass runs on the transcript
    /// before insertion. Pressing this while another recording is in
    /// flight just stops it — the cleanup intent is fixed at start time.
    func toggleAutoCleanupRecording() {
        if editModeContext != nil { return }

        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            cleanupRequestedForCurrentRecording = true
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
        // Esc cancels whichever flow is active. Edit-mode cancel restores
        // the saved pasteboard and bails without transcribing.
        if editModeContext != nil {
            cancelEditModeRecording()
            return
        }
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
    func retranscribeAsNew(_ recording: Recording, applyCleanup: Bool = false) {
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
            await retranscribeAsNewEntry(from: recording, applyCleanup: applyCleanup)
        }
    }

    // MARK: - Shortcuts

    func reloadShortcuts() {
        CustomShortcutMonitor.shared.reloadShortcuts()
    }

}
