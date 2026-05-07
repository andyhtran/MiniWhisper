import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "Transcription")

extension AppState {
    // MARK: - Transcription

    /// Runs the auto-cleanup LLM pass on a raw transcript when the
    /// caller passes `applyCleanup: true` (i.e. the recording was
    /// started via the Auto-Cleanup shortcut). Returns the (possibly
    /// cleaned) text + history metadata for the run, or `(rawText, nil)`
    /// when the caller opts out, the transcript is empty, or the call
    /// fails. Failures are intentionally silent — the user gets the raw
    /// transcript pasted instead of being blocked on a model error.
    func applyAutoCleanup(
        rawText: String, applyCleanup: Bool
    ) async -> (text: String, cleanup: RecordingCleanup?) {
        guard applyCleanup, !rawText.isEmpty else {
            return (rawText, nil)
        }

        let model = EditModeSettings.model
        let start = Date()

        // Surface the LLM phase as "Editing…" in the menu bar so the icon
        // shifts off `waveform.badge.ellipsis` (transcribing) onto
        // `wand.and.stars` (editing) for the duration of the cleanup call.
        isEditModeProcessing = true
        editModeProcessingCharCount = rawText.count
        defer {
            isEditModeProcessing = false
            editModeProcessingCharCount = 0
        }

        do {
            let cleaned: String
            switch model {
            case .custom:
                // Skip the call entirely if the user never wired up the
                // endpoint — without config we'd just throw and fall
                // back, which silently drops the user's cleanup intent.
                guard customEditProviderSettings.isConfigured else {
                    return (rawText, nil)
                }
                cleaned = try await customEditProvider.cleanupTranscript(
                    rawText, settings: customEditProviderSettings)
            case .gpt5Mini, .claudeHaiku45:
                cleaned = try await editModeProvider.cleanupTranscript(
                    rawText, model: model)
            }
            let duration = Date().timeIntervalSince(start)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (rawText, nil) }

            let backendModel: String = model == .custom
                ? customEditProviderSettings.modelName
                : model.rawValue
            let cleanup = RecordingCleanup(
                rawText: rawText,
                cleanedText: trimmed,
                backendModel: backendModel,
                cleanupDuration: duration
            )
            return (trimmed, cleanup)
        } catch {
            // Silent UX is intentional — fall back to the raw transcript so
            // the user isn't blocked. Log so device logs still capture the
            // failure for debugging.
            log.error("Auto-cleanup failed (\(model.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return (rawText, nil)
        }
    }

    /// Builds the formatter options from the current user settings.
    /// Snapshotted into a local so replacements + formatting see the
    /// same config across both halves of the pipeline.
    private func currentFormatterOptions() -> TranscriptionFormatter.Options {
        let rules = replacementSettings.enabled ? replacementSettings.enabledRules : []
        return TranscriptionFormatter.Options(
            replacementRules: rules,
            capitalization: FormattingSettings.capitalization,
            autoParagraph: FormattingSettings.autoParagraph,
            dropTrailingPunctuation: FormattingSettings.dropTrailingPunctuation,
            spokenSymbolsEnabled: SpokenSymbolsSettings.enabled,
            appendTrailingSpace: FormattingSettings.appendTrailingSpace
        )
    }

    private func applyPostProcessing(to text: String) -> String {
        TranscriptionFormatter.format(text, options: currentFormatterOptions())
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
        inputDeviceName: String, applyCleanup: Bool
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

            // Replacements → LLM cleanup → formatting. Replacements run
            // first so the user's explicit find/replace rules shape what
            // the LLM sees (e.g. `claw code` → `claude code` before the
            // model rewrites the sentence around it). Cosmetic formatting
            // runs after the LLM so capitalization/paragraph/trailing-
            // punctuation pick up its polish too.
            let options = currentFormatterOptions()
            let withReplacements = TranscriptionFormatter.applyReplacements(
                to: result.text, options: options)
            let cleanupResult = await applyAutoCleanup(
                rawText: withReplacements, applyCleanup: applyCleanup)
            let finalText = TranscriptionFormatter.applyFormatting(
                to: cleanupResult.text, options: options)

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
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                cleanup: cleanupResult.cleanup
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
                    language: "en",
                    provider: transcriptionMode.rawValue
                ),
                status: .failed
            )
            // Use saveMetadataOnly for failed recordings since audio may not exist
            try? recordingStore.saveFailedRecording(recording)
        }
    }

    func retranscribeCancelledRecording(_ recording: Recording) async {
        // Source audio may have been compressed to CAF by the retention
        // sweep — decode it to a temp WAV so VAD + the providers (which
        // expect WAV) keep working unchanged.
        let prepared: (url: URL, isTemporary: Bool)
        do {
            prepared = try await ensureWAVForTranscription(recording.audioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not decode audio: \(error.localizedDescription)")
            return
        }
        defer { cleanupTempAudio(prepared.url, isTemporary: prepared.isTemporary) }

        // Re-run VAD on the current raw WAV so the global toggle is the
        // source of truth. Overwrites any stale audio-vad.wav from the prior
        // run. No-op in the local modes — see `preprocessForUpload`.
        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: prepared.url,
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

            // Re-transcribed recordings don't carry the cleanup intent
            // forward — the user can re-record with the Auto-Cleanup
            // shortcut if they want a polished pass.
            let cleanupResult = await applyAutoCleanup(
                rawText: result.text, applyCleanup: false)
            let finalText = applyPostProcessing(to: cleanupResult.text)

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
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                cleanup: cleanupResult.cleanup
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
        // Preserve the source's audio format (wav or caf) so the hard-link
        // metadata + on-disk extension stay in sync.
        let sourceFileName = source.audioFileName ?? "audio.wav"
        let newAudioURL = newDir.appendingPathComponent(sourceFileName)

        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            // Hard-link avoids doubling disk usage; if one entry's audio is
            // retention-cleaned the other still works independently.
            try FileManager.default.linkItem(at: source.audioURL, to: newAudioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not prepare audio: \(error.localizedDescription)")
            return
        }

        // If the source had been compressed, decode the hard-linked CAF
        // to a temp WAV before VAD + the providers see it.
        let prepared: (url: URL, isTemporary: Bool)
        do {
            prepared = try await ensureWAVForTranscription(newAudioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not decode audio: \(error.localizedDescription)")
            return
        }
        defer { cleanupTempAudio(prepared.url, isTemporary: prepared.isTemporary) }

        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: prepared.url,
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
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                audioFileName: source.audioFileName  // mirror source's wav/caf choice
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

    /// Returns a WAV URL ready for VAD + transcription. WAV inputs pass
    /// through; CAF inputs (recordings compressed by the retention sweep)
    /// are decoded to a temp WAV off the main actor. Caller is
    /// responsible for `cleanupTempAudio` after use.
    func ensureWAVForTranscription(_ source: URL) async throws -> (url: URL, isTemporary: Bool) {
        if source.pathExtension.lowercased() == "wav" {
            return (source, false)
        }
        return try await Task.detached(priority: .userInitiated) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("decode_\(UUID().uuidString).wav")
            try AudioDecoder.decodeToWAV(inputURL: source, outputURL: tempURL)
            return (tempURL, true)
        }.value
    }

    func cleanupTempAudio(_ url: URL, isTemporary: Bool) {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
