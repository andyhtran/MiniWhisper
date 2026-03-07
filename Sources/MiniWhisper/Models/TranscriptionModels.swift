import Foundation

struct WordTiming: Codable, Equatable, Hashable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    let probability: Float
}

struct TranscriptionSegment: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { "\(start)-\(end)" }

    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [WordTiming]?
}

struct TranscriptionResult: Sendable {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String
    let duration: TimeInterval
    let model: String
}

struct SegmentsResult: Codable, Equatable, Sendable {
    let segments: [TranscriptionSegment]
    let totalDuration: TimeInterval
    let wordTimestampsEnabled: Bool
}
