import Foundation
import Observation

@Observable
@MainActor
final class RecordingStore: Sendable {
    private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default

    /// Cap on retained metadata + transcript entries. Each metadata blob
    /// is a few KB, so 500 ≈ a few MB total — cheap headroom for the
    /// "look back at last week's transcripts" use case.
    private let maxRecordings = 500

    /// After this many seconds we compress `audio.wav` to `audio.caf`
    /// (Opus, ~12× smaller) and drop the WAV. Re-transcribe paths use
    /// the WAV directly when present, otherwise decode CAF on the fly.
    private let wavRetentionInterval: TimeInterval = 30 * 60  // 30 minutes

    /// After this many seconds since `createdAt` we drop the audio file
    /// entirely (whether WAV or CAF). Metadata + transcript stay until
    /// pruned by `maxRecordings`.
    private let audioRetentionInterval: TimeInterval = 48 * 60 * 60  // 48 hours

    init() {
        ensureDirectoryExists()
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: Recording.baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    func saveWithExistingAudio(_ recording: Recording) throws {
        guard fileManager.fileExists(atPath: recording.audioURL.path) else {
            throw NSError(domain: "RecordingStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Audio file does not exist"
            ])
        }

        try saveMetadata(recording)
        try saveTranscriptionFiles(recording)

        recordings.removeAll { $0.id == recording.id }
        recordings.insert(recording, at: 0)
        performRetention()
    }

    func saveFailedRecording(_ recording: Recording) throws {
        try saveMetadata(recording)
        recordings.removeAll { $0.id == recording.id }
        recordings.insert(recording, at: 0)
        performRetention()
    }

    func delete(_ recording: Recording) throws {
        try? fileManager.removeItem(at: recording.storageDirectory)
        recordings.removeAll { $0.id == recording.id }
    }

    // MARK: - Loading

    func loadAll() async throws {
        let baseDir = Recording.baseDirectory
        let contents = (try? fileManager.contentsOfDirectory(atPath: baseDir.path)) ?? []
        var loaded: [Recording] = []

        for id in contents {
            let metadataURL = baseDir.appendingPathComponent(id).appendingPathComponent("metadata.json")
            do {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let recording = try decoder.decode(Recording.self, from: data)
                loaded.append(recording)
            } catch {
                // Skip directories without valid metadata (e.g. .DS_Store, partial writes)
                continue
            }
        }

        loaded.sort { $0.createdAt > $1.createdAt }
        recordings = loaded
    }

    // MARK: - Query

    var recentRecordings: [Recording] {
        Array(recordings.prefix(3))
    }

    var recentHistoryItems: [Recording] {
        let filtered = recordings.filter { recording in
            recording.transcription != nil || recording.status == .cancelled
        }
        return Array(filtered.prefix(3))
    }

    // MARK: - Retention

    func performRetention() {
        // Pass 1 — count prune. Drop the entire directory (metadata,
        // transcript, audio) for entries beyond the cap.
        if recordings.count > maxRecordings {
            let excess = Array(recordings[maxRecordings...])
            for recording in excess {
                try? delete(recording)
            }
        }

        let now = Date()
        let wavCutoff = now.addingTimeInterval(-wavRetentionInterval)
        let audioCutoff = now.addingTimeInterval(-audioRetentionInterval)

        // Pass 2 — drop expired audio (whether WAV or CAF) for anything
        // past the 48h audio retention window. Metadata stays.
        for recording in recordings {
            guard recording.createdAt < audioCutoff else { continue }
            if recording.hasAudioFile {
                try? fileManager.removeItem(at: recording.audioURL)
            }
            if recording.hasVADAudioFile {
                try? fileManager.removeItem(at: recording.vadAudioURL)
            }
        }

        // Pass 3 — collect WAVs older than the WAV window and compress
        // them to CAF off the main actor. Compression is slow on long
        // recordings (AVAudioConverter is sync, blocks the calling
        // thread) so we batch and run detached.
        let toCompress = recordings.filter {
            $0.createdAt < wavCutoff
                && $0.createdAt >= audioCutoff
                && $0.isAudioLossless
                && $0.hasAudioFile
        }

        // VAD audit artifact follows the WAV — once we've compressed the
        // source, the audit copy outlives its usefulness too. Drop here
        // to keep the WAV-window semantics consistent.
        for recording in toCompress {
            if recording.hasVADAudioFile {
                try? fileManager.removeItem(at: recording.vadAudioURL)
            }
        }

        if toCompress.isEmpty { return }
        scheduleCompression(of: toCompress)
    }

    private func scheduleCompression(of pending: [Recording]) {
        // Snapshot the URLs / IDs we need into a Sendable shape before
        // jumping off the main actor. Compression is purely file IO so
        // it doesn't touch any of the actor's mutable state directly.
        let jobs = pending.map { rec in
            CompressionJob(
                id: rec.id,
                wavURL: rec.audioURL,
                cafURL: rec.compressedAudioURL
            )
        }

        Task.detached(priority: .background) { [weak self] in
            for job in jobs {
                let result = Self.compressOne(job)
                if case .success = result {
                    await self?.markCompressed(id: job.id)
                }
            }
        }
    }

    /// Re-reads the in-memory recording, flips its `audioFileName` to
    /// `audio.caf`, and rewrites metadata.json. Runs back on the main
    /// actor because `recordings` is `@Observable`-tracked.
    private func markCompressed(id: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].audioFileName = "audio.caf"
        try? saveMetadata(recordings[index])
    }

    private struct CompressionJob: Sendable {
        let id: String
        let wavURL: URL
        let cafURL: URL
    }

    /// Encodes the WAV to a temp CAF, atomically moves it into place,
    /// then deletes the original WAV. Failures leave the WAV untouched
    /// so the next retention sweep can retry. `nonisolated` because it
    /// runs on a detached background task and only touches file IO.
    nonisolated private static func compressOne(_ job: CompressionJob) -> Result<Void, Error> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: job.wavURL.path) else {
            return .failure(NSError(domain: "RecordingStore", code: 100))
        }

        let tempURL = job.cafURL.deletingLastPathComponent()
            .appendingPathComponent("audio.caf.tmp")
        try? fm.removeItem(at: tempURL)

        do {
            try OpusEncoder.encode(inputURL: job.wavURL, outputURL: tempURL)
            if fm.fileExists(atPath: job.cafURL.path) {
                try fm.removeItem(at: job.cafURL)
            }
            try fm.moveItem(at: tempURL, to: job.cafURL)
            try fm.removeItem(at: job.wavURL)
            return .success(())
        } catch {
            try? fm.removeItem(at: tempURL)
            return .failure(error)
        }
    }

    // MARK: - Private

    private func saveTranscriptionFiles(_ recording: Recording) throws {
        let dir = recording.storageDirectory
        if let transcript = recording.transcription?.text {
            let transcriptURL = dir.appendingPathComponent("transcript.txt")
            try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        if let segments = recording.transcription?.segments, !segments.isEmpty {
            try saveSegments(segments, totalDuration: recording.recording.duration, to: dir)
        }
    }

    private func saveMetadata(_ recording: Recording) throws {
        let dir = recording.storageDirectory
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let metadataURL = dir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(recording)
        try data.write(to: metadataURL)
    }

    private func saveSegments(_ segments: [TranscriptionSegment], totalDuration: TimeInterval, to dir: URL) throws {
        let result = SegmentsResult(
            segments: segments,
            totalDuration: totalDuration,
            wordTimestampsEnabled: segments.contains { $0.words?.isEmpty == false }
        )
        let segmentsURL = dir.appendingPathComponent("segments.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        try data.write(to: segmentsURL)
    }
}
