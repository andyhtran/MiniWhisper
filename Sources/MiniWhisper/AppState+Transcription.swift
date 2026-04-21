import Foundation

extension AppState {
    // MARK: - Transcription

    /// Applies replacements + user-selected formatting rules to raw model
    /// output. Single entry point so every transcription path (new recording,
    /// re-transcribe, re-transcribe-as-new) produces byte-identical results.
    private func applyPostProcessing(to text: String) -> String {
        let rules = replacementSettings.enabled ? replacementSettings.enabledRules : []
        let options = TranscriptionFormatter.Options(
            replacementRules: rules,
            capitalization: FormattingSettings.capitalization,
            autoParagraph: FormattingSettings.autoParagraph,
            dropTrailingPunctuation: FormattingSettings.dropTrailingPunctuation,
            spokenSymbolsEnabled: SpokenSymbolsSettings.enabled
        )
        return TranscriptionFormatter.format(text, options: options)
    }

    /// Single choke point for VAD preprocessing: all three transcription entry
    /// points (fresh recording, re-transcribe cancelled, re-transcribe as new)
    /// funnel upload audio through here, and any failure inside the
    /// preprocessor falls back to the original WAV.
    ///
    /// Only applies to Custom (remote) mode — local models run on-device so
    /// trimming silence has no upload-cost benefit, and whisper.cpp has its
    /// own VAD pass built in.
    private func preprocessForUpload(
        audioURL: URL,
        duration: TimeInterval,
        storageDir: URL
    ) async -> (url: URL, applied: Bool) {
        guard transcriptionMode == .custom else {
            return (audioURL, false)
        }
        return await VADPreprocessor.shared.preprocess(
            audioURL: audioURL,
            durationSeconds: duration,
            recordingStorageDir: storageDir
        )
    }

    func transcribe(
        audioURL: URL, recordingId: String, duration: TimeInterval, sampleRate: Double,
        inputDeviceName: String
    ) async {
        let storageDir = audioURL.deletingLastPathComponent()
        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: audioURL,
            duration: duration,
            storageDir: storageDir
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            // Guard against stale callback: if the user rapid-tapped and started a new
            // recording while transcription was in-flight, the state has moved on.
            // Applying this result would desync state from the active recording.
            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let finalText = applyPostProcessing(to: result.text)

            pasteboard.copyAndPaste(finalText)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
                ?? 0

            let recording = Recording(
                id: recordingId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: duration,
                    sampleRate: sampleRate,
                    channels: 1,
                    fileSize: fileSize,
                    inputDevice: inputDeviceName,
                    vadApplied: vadApplied
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
                    inputDevice: inputDeviceName,
                    vadApplied: vadApplied
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

    func retranscribeCancelledRecording(_ recording: Recording) async {
        // Re-run VAD on the current raw WAV so the global toggle is the
        // source of truth. Overwrites any stale audio-vad.wav from the prior
        // run. No-op in the local modes — see `preprocessForUpload`.
        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: recording.audioURL,
            duration: recording.recording.duration,
            storageDir: recording.storageDirectory
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let finalText = applyPostProcessing(to: result.text)

            pasteboard.copyAndPaste(finalText)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: recording.audioURL.path)[.size]
                    as? Int64) ?? 0
            let updatedRecording = Recording(
                id: recording.id,
                createdAt: recording.createdAt,
                recording: RecordingInfo(
                    duration: recording.recording.duration,
                    sampleRate: recording.recording.sampleRate,
                    channels: recording.recording.channels,
                    fileSize: fileSize,
                    inputDevice: recording.recording.inputDevice,
                    vadApplied: vadApplied
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

    /// Creates a new recording entry by re-transcribing an existing completed
    /// recording's audio with the currently active model. Hard-links the audio
    /// file so both entries share the same bytes on disk.
    func retranscribeAsNewEntry(from source: Recording) async {
        let newId = Recording.generateId()
        let newDir = Recording.baseDirectory.appendingPathComponent(newId)
        let newAudioURL = newDir.appendingPathComponent("audio.wav")

        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            // Hard-link avoids doubling disk usage; if one entry's WAV is
            // retention-cleaned the other still works independently.
            try FileManager.default.linkItem(at: source.audioURL, to: newAudioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not prepare audio: \(error.localizedDescription)")
            return
        }

        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: newAudioURL,
            duration: source.recording.duration,
            storageDir: newDir
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let finalText = applyPostProcessing(to: result.text)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: newAudioURL.path)[.size]
                    as? Int64) ?? 0
            let newRecording = Recording(
                id: newId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: source.recording.duration,
                    sampleRate: source.recording.sampleRate,
                    channels: source.recording.channels,
                    fileSize: fileSize,
                    inputDevice: source.recording.inputDevice,
                    vadApplied: vadApplied
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

            try recordingStore.saveWithExistingAudio(newRecording)
            analyticsStore.record(
                duration: source.recording.duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()
        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Re-transcription Failed", message: error.localizedDescription)
        }
    }
}
