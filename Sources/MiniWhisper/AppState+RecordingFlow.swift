import AppKit
import Foundation

extension AppState {
    // MARK: - Recording Flow

    func startRecordingFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        defer { captureTransitionInFlight = false }

        guard recorder.state.isIdle else { return }
        guard isModelLoaded else {
            if transcriptionMode == .custom {
                toast.showError(
                    title: "Not Configured",
                    message: "Configure your custom endpoint before recording.")
            } else {
                toast.showError(
                    title: "Model Not Ready",
                    message: "Please wait for the model to finish loading.")
            }
            return
        }

        let recordingId = Recording.generateId()
        currentRecordingId = recordingId
        warningShown = false

        guard let resolvedDevice = deviceManager.resolveRecordingDevice() else {
            toast.showError(title: "Recording Failed", message: "No audio input device available")
            recorder.reset()
            currentRecordingId = nil
            return
        }

        if resolvedDevice.requestedMode == .specificDevice
            && resolvedDevice.didFallbackToSystemDefault
        {
            toast.show(
                ToastMessage(
                    type: .warning,
                    title: "Mic Unavailable",
                    message: "Selected mic not found, using system default"
                ))
        }

        let dir = Recording.baseDirectory.appendingPathComponent(recordingId)
        let audioURL = dir.appendingPathComponent("audio.wav")

        do {
            try await recorder.startRecording(to: audioURL, resolvedDevice: resolvedDevice)
            startDurationChecks()
            onRecordingStarted?()
        } catch {
            toast.showError(title: "Recording Failed", message: error.localizedDescription)
            recorder.reset()
            currentRecordingId = nil
        }
    }

    func stopAndTranscribeFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        defer { captureTransitionInFlight = false }

        guard recorder.state.isRecording else { return }

        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName

        // Sub-1s clips are nearly always an accidental toggle double-tap,
        // and whisper tends to hallucinate filler on them. Edit mode uses a
        // looser 0.5s threshold because it starts deliberately (a selection
        // must exist first), so accidental triggers are rare there.
        guard duration >= 1.0 else {
            await recorder.cancelRecording()
            recorder.reset()
            currentRecordingId = nil
            toast.showError(
                title: "Recording Too Short",
                message: "Nothing transcribed — try again and speak a bit longer.")
            return
        }

        guard let audioURL = await recorder.stopRecording() else {
            recorder.reset()
            currentRecordingId = nil
            return
        }

        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        // Snapshot + clear the cleanup flag before running transcribe.
        // Whether the recording was started via the Auto-Cleanup shortcut
        // is fixed at start time; stopping doesn't change the intent.
        let applyCleanup = cleanupRequestedForCurrentRecording
        cleanupRequestedForCurrentRecording = false

        await transcribe(
            audioURL: audioURL,
            recordingId: recordingId,
            duration: duration,
            sampleRate: sampleRate,
            inputDeviceName: inputDeviceName,
            applyCleanup: applyCleanup
        )
    }

    func cancelRecordingFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        defer { captureTransitionInFlight = false }

        guard recorder.state.isRecording else { return }

        cleanupRequestedForCurrentRecording = false
        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName
        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        guard let audioURL = await recorder.stopRecording() else {
            recorder.reset()
            return
        }
        recorder.reset()

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
                language: "en",
                provider: transcriptionMode.rawValue
            ),
            status: .cancelled
        )

        do {
            try recordingStore.saveWithExistingAudio(recording)
        } catch {
            toast.showError(title: "Cancel Save Failed", message: error.localizedDescription)
        }
    }
}
