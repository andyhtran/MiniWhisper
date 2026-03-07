import Foundation

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

    var audioURL: URL {
        storageDirectory.appendingPathComponent("audio.wav")
    }

    var storageDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id)
    }

    var hasAudioFile: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
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
