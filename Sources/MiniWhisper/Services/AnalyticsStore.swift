import Foundation
import Observation

@Observable
@MainActor
final class AnalyticsStore: Sendable {
    private(set) var totals = Totals()

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MiniWhisper/analytics.json")
    }

    struct Totals: Codable {
        var totalRecordings: Int = 0
        var totalDuration: TimeInterval = 0
        var totalWords: Int = 0
    }

    // MARK: - Computed

    var formattedSpeakingTime: String {
        Self.formatDuration(Int(totals.totalDuration))
    }

    var averageWPM: Int {
        Self.calculateWPM(totalWords: totals.totalWords, totalDuration: totals.totalDuration)
    }

    nonisolated static func formatDuration(_ totalSeconds: Int) -> String {
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    nonisolated static func calculateWPM(totalWords: Int, totalDuration: TimeInterval) -> Int {
        guard totalDuration >= 60 else { return 0 }
        return Int(Double(totalWords) / (totalDuration / 60))
    }

    var formattedRecordings: String {
        Self.compactNumber(totals.totalRecordings)
    }

    var formattedWords: String {
        Self.compactNumber(totals.totalWords)
    }

    nonisolated static func compactNumber(_ value: Int) -> String {
        switch value {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            let k = Double(value) / 1_000
            return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        default:
            let m = Double(value) / 1_000_000
            return m >= 10 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        }
    }

    // MARK: - Persistence

    /// Loads analytics from disk. Returns true if the file existed.
    @discardableResult
    func load() -> Bool {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Totals.self, from: data) else {
            return false
        }
        totals = decoded
        return true
    }

    func seedFromRecordings(_ recordings: [Recording]) {
        for recording in recordings {
            guard recording.recording.duration >= 1.0,
                  let transcription = recording.transcription else { continue }

            totals.totalRecordings += 1
            totals.totalDuration += recording.recording.duration
            totals.totalWords += transcription.text.split(separator: " ").count
        }
        save()
    }

    func record(duration: TimeInterval, wordCount: Int) {
        totals.totalRecordings += 1
        totals.totalDuration += duration
        totals.totalWords += wordCount
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(totals) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
