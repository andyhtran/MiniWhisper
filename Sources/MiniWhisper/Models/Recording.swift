import Foundation

enum RecordingStatus: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case failed
    case cancelled
}

struct RecordingInfo: Codable, Equatable, Hashable, Sendable {
    let duration: TimeInterval
    let sampleRate: Double
    let channels: Int
    let fileSize: Int64
    let inputDevice: String?
    /// Whether client-side VAD preprocessing was applied before upload.
    /// `nil` on recordings created before the VAD feature existed — those
    /// decode cleanly since it's optional, so no migration is needed.
    var vadApplied: Bool?

    init(
        duration: TimeInterval,
        sampleRate: Double,
        channels: Int,
        fileSize: Int64,
        inputDevice: String?,
        vadApplied: Bool? = nil
    ) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileSize = fileSize
        self.inputDevice = inputDevice
        self.vadApplied = vadApplied
    }
}

struct RecordingTranscription: Codable, Equatable, Hashable, Sendable {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String
    let model: String
    let transcriptionDuration: TimeInterval
}

struct RecordingConfiguration: Codable, Equatable, Hashable, Sendable {
    let voiceModel: String
    let language: String
}

struct Recording: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let createdAt: Date
    let recording: RecordingInfo
    var transcription: RecordingTranscription?
    let configuration: RecordingConfiguration
    var status: RecordingStatus

    init(
        id: String,
        createdAt: Date,
        recording: RecordingInfo,
        transcription: RecordingTranscription?,
        configuration: RecordingConfiguration,
        status: RecordingStatus = .completed
    ) {
        self.id = id
        self.createdAt = createdAt
        self.recording = recording
        self.transcription = transcription
        self.configuration = configuration
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case recording
        case transcription
        case configuration
        case status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        recording = try container.decode(RecordingInfo.self, forKey: .recording)
        transcription = try container.decodeIfPresent(RecordingTranscription.self, forKey: .transcription)
        configuration = try container.decode(RecordingConfiguration.self, forKey: .configuration)
        status = try container.decodeIfPresent(RecordingStatus.self, forKey: .status)
            ?? (transcription == nil ? .failed : .completed)
    }

    var audioURL: URL {
        storageDirectory.appendingPathComponent("audio.wav")
    }

    /// Optional audit artifact: the VAD-preprocessed WAV actually sent to the
    /// transcription provider. Present only when `RecordingInfo.vadApplied`
    /// is true and the 15-minute retention window hasn't elapsed.
    var vadAudioURL: URL {
        storageDirectory.appendingPathComponent("audio-vad.wav")
    }

    var storageDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id)
    }

    var hasAudioFile: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    var hasVADAudioFile: Bool {
        FileManager.default.fileExists(atPath: vadAudioURL.path)
    }

    var canRetranscribe: Bool {
        status == .cancelled && transcription == nil && hasAudioFile
    }

    /// Completed recordings can be re-transcribed with a different model,
    /// producing a new history entry. Only available while the WAV still exists
    /// (before the 15-minute retention cleanup).
    var canRetranscribeAsNew: Bool {
        status == .completed && transcription != nil && hasAudioFile
    }

    static var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MiniWhisper/recordings")
    }

    static func generateId() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        return String(ms)
    }
}
