import AVFoundation
import Foundation
@preconcurrency import FluidAudio
import os

/// Client-side VAD preprocessing that runs between recording and upload.
/// Preprocessor resamples to 16 kHz mono, runs Silero VAD, and reconstructs the
/// audio with long silences *capped* (not removed) — Whisper still needs short
/// pauses for punctuation. Output is written alongside the raw WAV for audit.
///
/// Any failure at any step silently falls back to the original WAV. The feature
/// is meant to be invisible whether it works or breaks.
///
/// Actor isolation lets us lazily initialize `VadManager` once per app session
/// and reuse it across transcriptions.
actor VADPreprocessor {
    static let shared = VADPreprocessor()

    private let logger = Logger(subsystem: Logger.subsystem, category: "VADPreprocessor")

    /// Clips shorter than this skip VAD entirely. Whisper's silence-induced
    /// hallucination needs at least one mid-thought pause to trigger, and a
    /// ~8 s window is the smallest where that's realistic while still letting
    /// short voice commands ("set a timer for five minutes") pass through
    /// untouched.
    private let minClipDurationForVAD: TimeInterval = 8.0

    /// Silences between segments get capped at this duration — preserving
    /// prosody/punctuation cues but cutting dead air long enough to confuse
    /// the model.
    private let maxInterSegmentSilence: TimeInterval = 0.5

    /// Trailing tail length. We take this much *real audio* from past the
    /// last segment rather than appending hard zeros — Whisper was trained on
    /// audio with natural noise floor and treats perfect digital silence as
    /// out-of-distribution (it triggers "Thank you." / "thanks for watching"
    /// hallucination artifacts).
    private let trailingSilence: TimeInterval = 0.2

    /// Safety net: if we collapsed the audio below half its input duration,
    /// something probably went wrong (aggressive threshold, mic issue, user
    /// whispering). Fall back rather than ship a suspiciously short file.
    private let minKeepRatio: Double = 0.5

    private var vadManager: VadManager?
    private var initFailed = false

    private init() {}

    /// Preprocess `audioURL` and return the URL to upload. Never throws.
    /// - Returns: The preprocessed WAV URL when VAD ran successfully, or the
    ///   original `audioURL` on any failure / skip condition. `applied` reports
    ///   which branch was taken so it can be persisted to metadata.
    func preprocess(
        audioURL: URL,
        durationSeconds: Double,
        recordingStorageDir: URL
    ) async -> (url: URL, applied: Bool) {
        guard VADSettings.enabled else {
            return (audioURL, false)
        }

        guard durationSeconds >= minClipDurationForVAD else {
            logger.debug("Clip \(durationSeconds, format: .fixed(precision: 1))s below threshold, skipping VAD")
            return (audioURL, false)
        }

        let samples: [Float]
        do {
            let converter = AudioConverter()
            samples = try converter.resampleAudioFile(audioURL)
        } catch {
            logger.warning("VAD resample failed, using original audio: \(error.localizedDescription)")
            return (audioURL, false)
        }

        guard !samples.isEmpty else {
            return (audioURL, false)
        }

        let manager: VadManager
        do {
            manager = try await vadManagerOrInit()
        } catch {
            logger.warning("VAD init failed, using original audio: \(error.localizedDescription)")
            return (audioURL, false)
        }

        logger.info("Running VAD on \(durationSeconds, format: .fixed(precision: 1))s clip")

        let segments: [VadSegment]
        do {
            // Whisper's 30s attention window benefits from long, contiguous
            // context. Splitting on every natural breath (~400 ms pause)
            // creates too many splice points and hurts punctuation plus
            // boundary-word capture — Whisper tends to hallucinate when
            // chunks are short and padding is thin. minSilenceDuration=2.0
            // only segments at real mid-thought pauses; speechPadding=0.4
            // keeps leading/trailing phonemes intact across each cut.
            //
            // FluidAudio's VadSegmentationConfig.init uses
            // precondition/assert that TRAP the process (not throw) if
            // these are violated, so values must satisfy:
            //   speechPadding <= minSpeechDuration
            //   minSilenceDuration <= maxSpeechDuration
            //   all durations >= 0, maxSpeechDuration > 0
            // minSpeechDuration=0.4 matches speechPadding to satisfy the
            // first invariant.
            let segConfig = VadSegmentationConfig(
                minSpeechDuration: 0.4,
                minSilenceDuration: 2.0,
                speechPadding: 0.4
            )
            segments = try await manager.segmentSpeech(samples, config: segConfig)
        } catch {
            logger.warning("VAD post-processing failed, using original: \(error.localizedDescription)")
            return (audioURL, false)
        }

        guard !segments.isEmpty else {
            logger.warning("VAD found no speech, using original audio")
            return (audioURL, false)
        }

        let sampleRate = VadManager.sampleRate
        let reconstructed = reconstruct(
            samples: samples,
            segments: segments,
            sampleRate: sampleRate
        )

        let inputDurSec = Double(samples.count) / Double(sampleRate)
        let outputDurSec = Double(reconstructed.count) / Double(sampleRate)
        let keepRatio = inputDurSec > 0 ? outputDurSec / inputDurSec : 0

        guard keepRatio >= minKeepRatio else {
            logger.warning("VAD kept only \(Int(keepRatio * 100))% — suspicious, using original")
            return (audioURL, false)
        }

        let vadURL = recordingStorageDir.appendingPathComponent("audio-vad.wav")
        do {
            try writeWAV(samples: reconstructed, sampleRate: sampleRate, to: vadURL)
        } catch {
            logger.warning("VAD post-processing failed, using original: \(error.localizedDescription)")
            return (audioURL, false)
        }

        // longestSegment exposes whether VAD is under-segmenting: if it's
        // close to inputDurSec, threshold/minSilenceDuration tuning needs
        // attention — most silences are being absorbed rather than split.
        let longestSegment = segments.map { $0.duration }.max() ?? 0
        logger.info(
            "VAD: \(inputDurSec, format: .fixed(precision: 1))s → \(outputDurSec, format: .fixed(precision: 1))s, \(segments.count) segments (longest \(longestSegment, format: .fixed(precision: 1))s), kept \(Int(keepRatio * 100))%"
        )
        return (vadURL, true)
    }

    // MARK: - Private

    private func vadManagerOrInit() async throws -> VadManager {
        if let manager = vadManager { return manager }
        if initFailed {
            throw VadError.notInitialized
        }
        do {
            // 0.5 is the middle ground between FluidAudio's default (0.85)
            // and our earlier over-lenient 0.35. The derived negativeThreshold
            // (threshold − 0.15) determines when a frame counts as silence;
            // at 0.35 the negative threshold was 0.20, which mic noise floor
            // and breathing clear easily — so the "silence timer" that ends
            // segments barely ever started. At 0.5 the negative threshold is
            // 0.35, which reliably reads ambient room tone as silence while
            // still catching quiet syllables at word boundaries.
            let config = VadConfig(defaultThreshold: 0.5)
            let manager = try await VadManager(config: config)
            vadManager = manager
            return manager
        } catch {
            initFailed = true
            throw error
        }
    }

    /// Stitch kept segments together, capping inter-segment silences and
    /// appending a trailing tail. Works in Float32 at 16 kHz.
    ///
    /// Critical invariant: every sample written to the output comes from the
    /// original `samples` buffer — we never insert `Float(0)` padding. Hard
    /// digital zeros are out-of-distribution for Whisper (trained on audio
    /// with natural noise floor) and reliably trigger hallucination artifacts
    /// like a tacked-on " Thank you." or full repetition loops. Copying a
    /// slice of the real original silence preserves room tone and mic noise,
    /// so the cut points are audibly and statistically identical to the raw
    /// audio.
    private func reconstruct(
        samples: [Float],
        segments: [VadSegment],
        sampleRate: Int
    ) -> [Float] {
        let capSamples = Int(maxInterSegmentSilence * Double(sampleRate))
        let tailSamples = Int(trailingSilence * Double(sampleRate))
        let totalSamples = samples.count

        var output: [Float] = []
        output.reserveCapacity(samples.count)

        for (index, segment) in segments.enumerated() {
            let start = max(0, min(segment.startSample(sampleRate: sampleRate), totalSamples))
            let end = max(start, min(segment.endSample(sampleRate: sampleRate), totalSamples))
            if end > start {
                output.append(contentsOf: samples[start..<end])
            }

            // Inter-segment gap: take up to `capSamples` of ORIGINAL audio
            // starting where this segment ended. If the real gap is shorter
            // than the cap we take all of it (nothing removed here). If it's
            // longer we keep only the first `capSamples` — the natural
            // "fade into silence" right after speech ends — and drop the
            // rest. This trims long dead air without introducing zeros.
            if index < segments.count - 1 {
                let nextStart = max(end, min(segments[index + 1].startSample(sampleRate: sampleRate), totalSamples))
                let copyEnd = min(end + capSamples, nextStart)
                if copyEnd > end {
                    output.append(contentsOf: samples[end..<copyEnd])
                }
            }
        }

        // Trailing tail: prefer real audio past the last segment's padded
        // end. If the last segment already reaches EOF, fall back to the
        // final `tailSamples` of the original file so the output still ends
        // with natural noise floor instead of a hard boundary.
        if let lastSegment = segments.last, tailSamples > 0 {
            let lastEnd = max(0, min(lastSegment.endSample(sampleRate: sampleRate), totalSamples))
            let tailEnd = min(lastEnd + tailSamples, totalSamples)
            if tailEnd > lastEnd {
                output.append(contentsOf: samples[lastEnd..<tailEnd])
            } else if totalSamples >= tailSamples {
                let fallbackStart = totalSamples - tailSamples
                output.append(contentsOf: samples[fallbackStart..<totalSamples])
            }
        }

        return output
    }

    /// Write a mono Float32 `[Float]` buffer to disk as a 32-bit float PCM WAV.
    ///
    /// Why Float32 instead of Int16: `WhisperProvider.resampleTo16kHz` has a
    /// fast path for 16 kHz mono Float32 inputs and a separate conversion path
    /// for non-Float32 inputs. The conversion path pre-sets the output buffer's
    /// `frameLength` before `AVAudioConverter.convert(...)` which causes it to
    /// write zero frames — whisper then sees silence and returns an empty
    /// transcription. Writing Float32 keeps us on the fast path and matches
    /// the on-disk format of the raw audio.wav.
    private nonisolated func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let outputFile = try AVAudioFile(forWriting: url, settings: settings)

        guard let bufferFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VADPreprocessor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create audio buffer format"
            ])
        }

        // AVAudioFile.write(from:) accepts up to ~UInt32.max frames per call,
        // but chunking keeps peak memory bounded for long recordings.
        let chunkSize = 16384
        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            let frameCount = AVAudioFrameCount(end - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount) else {
                throw NSError(domain: "VADPreprocessor", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not allocate PCM buffer"
                ])
            }
            buffer.frameLength = frameCount
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                buffer.floatChannelData![0].update(from: base.advanced(by: index), count: Int(frameCount))
            }
            try outputFile.write(from: buffer)
            index = end
        }
    }
}
