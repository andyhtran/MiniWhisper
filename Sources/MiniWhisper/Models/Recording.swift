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

    var storageDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id)
    }

    var hasAudioFile: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    var canRetranscribe: Bool {
        status == .cancelled && transcription == nil && hasAudioFile
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
