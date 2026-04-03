import Foundation
import Observation

@Observable
@MainActor
final class RecordingStore: Sendable {
    private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default

    private let maxRecordings = 50
    private let wavRetentionInterval: TimeInterval = 15 * 60  // 15 minutes

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
        if recordings.count > maxRecordings {
            let excess = Array(recordings[maxRecordings...])
            for recording in excess {
                try? delete(recording)
            }
        }

        // Clean up old WAV files (keep metadata/transcript)
        let cutoff = Date().addingTimeInterval(-wavRetentionInterval)
        for recording in recordings {
            if recording.createdAt < cutoff && recording.hasAudioFile {
                let audioURL = recording.audioURL
                try? fileManager.removeItem(at: audioURL)
            }
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
