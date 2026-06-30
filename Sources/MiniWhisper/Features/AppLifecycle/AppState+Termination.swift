import Foundation

extension AppState {
    var needsTerminationCleanup: Bool {
        recorder.state.isRecording
            || recorder.state == .processing
            || editModeContext != nil
            || isEditModeProcessing
            || durationCheckTimer != nil
            || captureTransitionInFlight
    }

    func prepareForTermination() async {
        stopDurationChecks()
        permissions.stopPolling()
        onRecordingEnded?()
        cleanupRequestedForCurrentRecording = false
        captureTransitionInFlight = false
        isEditModeProcessing = false
        editModeProcessingCharCount = 0

        if let context = editModeContext {
            editModeContext = nil
            pasteboard.restoreSavedPasteboard(context.savedPasteboard)
            await recorder.cancelRecording()
            recordingStore.discard(id: context.recordingId)
            recorder.reset()
            currentRecordingId = nil
            return
        }

        pasteboard.restorePendingPasteboard()

        guard recorder.state.isRecording else {
            recorder.reset()
            currentRecordingId = nil
            return
        }

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName
        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        guard let audioURL = await recorder.stopRecording() else {
            recordingStore.discardIfStillInProgress(id: recordingId)
            recorder.reset()
            return
        }

        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let recording = Recording(
            id: recordingId,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: duration,
                sampleRate: sampleRate,
                channels: 1,
                fileSize: fileSize,
                inputDevice: inputDeviceName
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: transcriptionMode.modelDisplayName,
                language: "auto",
                provider: transcriptionMode.rawValue
            ),
            status: .failed
        )
        try? recordingStore.saveFailedRecording(recording)
        recorder.reset()
    }
}
