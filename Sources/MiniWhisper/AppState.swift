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

    var selectionEnabled: Bool { editModeBehavior.selectionEnabled }
    var autoCleanupEnabled: Bool { editModeBehavior.autoCleanupEnabled }
    var voiceEditEnabled: Bool = EditModeSettings.voiceEdit
    var showMenuBarVisibilityHint = false
    var modelLoadState = ModelLoadState.idle

    /// Tags preload/switch tasks so stale progress from an old model choice
    /// cannot flip the header after the user has moved on.
    private var modelLoadGeneration = 0

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

    var isModelLoaded: Bool { modelLoadState.isReady }

    init() {
        modelLoadState = initialModelLoadState(for: transcriptionMode)

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
        loadSelectedTranscriptionModel()
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
        loadSelectedTranscriptionModel()
    }

    func refreshCustomTranscriptionReadiness() {
        guard transcriptionMode == .custom else { return }
        modelLoadGeneration += 1
        modelLoadState = initialModelLoadState(for: .custom)
    }

    private func loadSelectedTranscriptionModel() {
        let mode = transcriptionMode
        modelLoadGeneration += 1
        let generation = modelLoadGeneration

        guard mode != .custom else {
            modelLoadState = initialModelLoadState(for: mode)
            return
        }

        modelLoadState = .loading(phase: .checking, progress: nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let progressHandler = self.makeModelProgressHandler(for: mode, generation: generation)
                switch mode {
                case .default:
                    try await self.parakeet.initialize(progressHandler: progressHandler)
                case .multilingual:
                    try await self.whisper.initialize(progressHandler: progressHandler)
                case .custom:
                    return
                }

                guard self.isCurrentModelLoad(mode: mode, generation: generation) else { return }
                self.modelLoadState = .ready
            } catch {
                guard self.isCurrentModelLoad(mode: mode, generation: generation) else { return }
                self.modelLoadState = .failed(error.localizedDescription)
                self.toast.showError(title: "Model Load Failed", message: error.localizedDescription)
            }
        }
    }

    private func makeModelProgressHandler(
        for mode: TranscriptionMode,
        generation: Int
    ) -> ModelLoadProgressHandler {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentModelLoad(mode: mode, generation: generation),
                      !self.modelLoadState.isReady,
                      self.modelLoadState.failureMessage == nil else { return }
                self.modelLoadState = .loading(phase: progress.phase, progress: progress.progress)
            }
        }
    }

    private func isCurrentModelLoad(mode: TranscriptionMode, generation: Int) -> Bool {
        generation == modelLoadGeneration && mode == transcriptionMode
    }

    private func initialModelLoadState(for mode: TranscriptionMode) -> ModelLoadState {
        switch mode {
        case .default, .multilingual:
            return .idle
        case .custom:
            return customProviderSettings.isConfigured ? .ready : .idle
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
