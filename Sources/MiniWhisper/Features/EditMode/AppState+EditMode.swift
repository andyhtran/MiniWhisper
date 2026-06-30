import Foundation

extension AppState {
    /// Edit-selection shortcut handler. Behavior depends on the voice
    /// edit toggle:
    ///
    /// **Voice edit off (default):** single-press — captures the
    /// selection, runs the cleanup LLM immediately, pastes the result.
    ///
    /// **Voice edit on:** two-press flow — first press captures
    /// selection + starts recording a voice instruction, second press
    /// stops recording and applies the instruction to the selection.
    func editSelection() {
        guard selectionEnabled else { return }

        if editModeContext != nil {
            Task { await stopAndApplyEditFlow() }
            return
        }

        guard recorder.state.isIdle else { return }

        if EditModeSettings.model == .custom,
           !customEditProviderSettings.isConfigured
        {
            toast.showError(
                title: "Not Configured",
                message: "Configure your custom edit endpoint before using edit mode.")
            return
        }

        if voiceEditEnabled {
            guard isModelLoaded else {
                if transcriptionMode == .custom {
                    toast.showError(
                        title: "Not Configured",
                        message: "Configure your custom transcription endpoint before using edit mode.")
                } else if let message = modelLoadState.failureMessage {
                    toast.showError(title: "Model Load Failed", message: message)
                } else {
                    toast.showError(
                        title: "Model Not Ready",
                        message: "Please wait for the transcription model to finish loading.")
                }
                return
            }
            Task { await startEditModeFlow() }
        } else {
            Task { await cleanupSelectionFlow() }
        }
    }

    func cancelEditModeRecording() {
        guard let context = editModeContext else { return }
        editModeContext = nil
        onRecordingEnded?()

        Task {
            await recorder.cancelRecording()
            recorder.reset()
            pasteboard.restoreSavedPasteboard(context.savedPasteboard)
        }
    }

    /// Single-press cleanup: captures the selection, runs the cleanup
    /// LLM, and pastes the result — no recording involved.
    private func cleanupSelectionFlow() async {
        guard let captured = await pasteboard.captureSelection() else {
            toast.showError(
                title: "Nothing to Clean Up",
                message: "Select text in any app, then press your edit shortcut.")
            return
        }

        if captured.text.count > EditModeProvider.hardCharThreshold {
            pasteboard.restoreSavedPasteboard(captured.saved)
            let formatted = captured.text.count.formatted(.number.grouping(.automatic))
            toast.showError(
                title: "Selection Too Large",
                message: "Selection cleanup is for focused edits — \(formatted) chars is over the limit. Try a smaller chunk.")
            return
        }

        recorder.state = .processing
        isEditModeProcessing = true
        editModeProcessingCharCount = captured.text.count
        defer {
            isEditModeProcessing = false
            editModeProcessingCharCount = 0
        }

        let (cleanedText, cleanup) = await applyAutoCleanup(
            rawText: captured.text, applyCleanup: true)

        recorder.reset()

        guard let cleanup else {
            pasteboard.restoreSavedPasteboard(captured.saved)
            toast.showError(
                title: "Cleanup Failed",
                message: "Could not clean up the selected text. Check your edit model configuration.")
            return
        }

        saveSelectionCleanup(cleanup: cleanup)
        pasteboard.pasteAndRestore(cleanedText, savedPasteboard: captured.saved)
    }

    private func saveSelectionCleanup(cleanup: RecordingCleanup) {
        let recording = Recording(
            id: Recording.generateId(),
            createdAt: Date(),
            recording: RecordingInfo(
                duration: 0, sampleRate: 0, channels: 0, fileSize: 0,
                inputDevice: nil),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: "", language: ""),
            status: .completed,
            cleanup: cleanup
        )

        try? recordingStore.saveFailedRecording(recording)
    }

    private func startEditModeFlow() async {
        guard let captured = await pasteboard.captureSelection() else {
            toast.showError(
                title: "Nothing to Edit",
                message: "Select text in any app, then press your edit shortcut.")
            return
        }

        // Refuse oversized selections before we record anything — saves
        // the user from speaking an instruction they can't apply.
        if captured.text.count > EditModeProvider.hardCharThreshold {
            pasteboard.restoreSavedPasteboard(captured.saved)
            let formatted = captured.text.count.formatted(.number.grouping(.automatic))
            toast.showError(
                title: "Selection Too Large",
                message: "Edit mode is for focused edits — \(formatted) chars is over the limit. Try a smaller chunk.")
            return
        }

        guard let resolvedDevice = deviceManager.resolveRecordingDevice() else {
            pasteboard.restoreSavedPasteboard(captured.saved)
            toast.showError(title: "Recording Failed", message: "No audio input device available")
            return
        }

        let recordingId = Recording.generateId()
        let dir = Recording.baseDirectory.appendingPathComponent(recordingId)
        let audioURL = dir.appendingPathComponent("audio.wav")

        do {
            try await recorder.startRecording(to: audioURL, resolvedDevice: resolvedDevice)
            editModeContext = EditModeContext(
                selectedText: captured.text,
                savedPasteboard: captured.saved,
                recordingId: recordingId
            )
            // Tell HotkeyManager recording is active so cancel shortcut (Esc) is enabled.
            onRecordingStarted?()
        } catch {
            pasteboard.restoreSavedPasteboard(captured.saved)
            recorder.reset()
            toast.showError(title: "Recording Failed", message: error.localizedDescription)
        }
    }

    private func stopAndApplyEditFlow() async {
        guard let context = editModeContext else { return }
        editModeContext = nil
        onRecordingEnded?()

        // Snapshot recorder metadata BEFORE stop/reset — those zero out
        // `actualSampleRate` and `actualInputDeviceName`.
        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName

        // Below ~0.5s is almost always an accidental press — don't bother
        // round-tripping through transcribe + chat for a sub-half-second clip.
        guard duration >= 0.5 else {
            await recorder.cancelRecording()
            recorder.reset()
            pasteboard.restoreSavedPasteboard(context.savedPasteboard)
            toast.showError(
                title: "Edit Cancelled",
                message: "Instruction was too short. Try again and speak the edit you want.")
            return
        }

        guard let audioURL = await recorder.stopRecording() else {
            recorder.reset()
            pasteboard.restoreSavedPasteboard(context.savedPasteboard)
            toast.showError(title: "Recording Failed", message: "Could not save audio.")
            return
        }

        recorder.state = .processing
        isEditModeProcessing = true
        editModeProcessingCharCount = context.selectedText.count
        defer {
            isEditModeProcessing = false
            editModeProcessingCharCount = 0
        }

        let model = EditModeSettings.model

        do {
            let transcription = try await transcribeEditModeAudio(at: audioURL)

            guard !transcription.text.isEmpty else {
                recorder.reset()
                pasteboard.restoreSavedPasteboard(context.savedPasteboard)
                toast.showError(
                    title: "Edit Failed", message: "No instruction transcribed.")
                return
            }

            let editStart = Date()
            let edited: String
            switch model {
            case .custom:
                edited = try await customEditProvider.editText(
                    instruction: transcription.text,
                    selection: context.selectedText,
                    settings: customEditProviderSettings)
            case .gpt5Mini, .claudeHaiku45:
                edited = try await editModeProvider.editText(
                    instruction: transcription.text,
                    selection: context.selectedText,
                    model: model)
            }
            let editDuration = Date().timeIntervalSince(editStart)

            recorder.reset()

            guard !edited.isEmpty else {
                pasteboard.restoreSavedPasteboard(context.savedPasteboard)
                toast.showError(
                    title: "Edit Failed", message: "Model returned an empty response.")
                return
            }

            saveEditModeRecording(
                id: context.recordingId,
                audioURL: audioURL,
                duration: duration,
                sampleRate: sampleRate,
                inputDeviceName: inputDeviceName,
                transcription: transcription,
                originalSelection: context.selectedText,
                editedResult: edited,
                model: model,
                editDuration: editDuration
            )

            pasteboard.pasteAndRestore(edited, savedPasteboard: context.savedPasteboard)
        } catch {
            recorder.reset()
            pasteboard.restoreSavedPasteboard(context.savedPasteboard)
            toast.showError(title: "Edit Failed", message: error.localizedDescription)
        }
    }

    /// Mirrors the dispatch in `AppState+Transcription` so edit mode
    /// works with whichever transcription model is currently selected.
    /// VAD preprocessing is skipped for edit mode — instructions are
    /// short and the savings don't matter.
    private func transcribeEditModeAudio(at audioURL: URL) async throws -> TranscriptionResult {
        switch transcriptionMode {
        case .default:
            return try await parakeet.transcribe(audioURL: audioURL)
        case .multilingual:
            return try await whisper.transcribe(audioURL: audioURL)
        case .custom:
            return try await customProvider.transcribe(
                audioURL: audioURL, settings: customProviderSettings)
        }
    }

    private func saveEditModeRecording(
        id: String,
        audioURL: URL,
        duration: TimeInterval,
        sampleRate: Double,
        inputDeviceName: String,
        transcription: TranscriptionResult,
        originalSelection: String,
        editedResult: String,
        model: EditModeModel,
        editDuration: TimeInterval
    ) {
        let backend = model.backend
        // For `.custom` the canonical "what model ran this" string is the
        // user-typed model name from settings — not the literal "custom"
        // enum tag. Captured at save time so history rows surface the
        // real model (e.g. `gpt-4o-mini`) the user pointed us at.
        let backendModel: String = model == .custom
            ? customEditProviderSettings.modelName
            : model.rawValue
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
            ?? 0

        let recording = Recording(
            id: id,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: duration,
                sampleRate: sampleRate,
                channels: 1,
                fileSize: fileSize,
                inputDevice: inputDeviceName,
                vadApplied: false
            ),
            transcription: RecordingTranscription(
                text: transcription.text,
                segments: transcription.segments,
                language: transcription.language,
                model: transcription.model,
                transcriptionDuration: transcription.duration
            ),
            configuration: RecordingConfiguration(
                voiceModel: transcription.model,
                language: transcription.language,
                provider: transcriptionMode.rawValue
            ),
            status: .completed,
            editMode: RecordingEditMode(
                originalSelection: originalSelection,
                editedResult: editedResult,
                backend: backend.rawValue,
                backendDisplayName: backend.displayName,
                backendModel: backendModel,
                editDuration: editDuration
            )
        )

        do {
            try recordingStore.saveWithExistingAudio(recording)
        } catch {
            // History save is non-critical — the edit already pasted. Surface
            // as a quiet log rather than a toast that interrupts the user.
            toast.showError(
                title: "History Save Failed", message: error.localizedDescription)
        }
    }
}
