import Foundation

enum OutputFormat: String {
    case text
    case json
    case srt
    case vtt

    static func infer(from path: String) -> OutputFormat? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "txt": return .text
        case "json": return .json
        case "srt": return .srt
        case "vtt": return .vtt
        default: return nil
        }
    }
}

enum TimestampMode: String {
    case none
    case segment
    case word
}

struct TranscriptionRangeOutput: Encodable {
    let startSeconds: Double
    let endSeconds: Double
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case durationSeconds = "duration_seconds"
    }
}

struct SegmentTimingOutput: Encodable {
    let startTime: Double
    let endTime: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case text
    }
}

enum TranscribeRenderer {
    static func render(_ output: TranscriptionJSONOutput, format: OutputFormat) throws -> String {
        switch format {
        case .text:
            return output.text + "\n"
        case .json:
            return try JSONPrinter.string(from: output) + "\n"
        case .srt:
            return renderSRT(cues: cues(for: output))
        case .vtt:
            return renderVTT(cues: cues(for: output))
        }
    }

    private static func cues(for output: TranscriptionJSONOutput) -> [SegmentTimingOutput] {
        if !output.subtitleSegments.isEmpty {
            return output.subtitleSegments
        }
        if !output.segments.isEmpty {
            return output.segments
        }
        guard !output.text.isEmpty else { return [] }
        return [SegmentTimingOutput(startTime: 0, endTime: output.durationSeconds, text: output.text)]
    }

    private static func renderSRT(cues: [SegmentTimingOutput]) -> String {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append(String(index + 1))
            lines.append("\(formatSRTTime(cue.startTime)) --> \(formatSRTTime(cue.endTime))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderVTT(cues: [SegmentTimingOutput]) -> String {
        var lines = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(formatVTTTime(cue.startTime)) --> \(formatVTTTime(cue.endTime))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        formatTime(seconds, millisecondSeparator: ",")
    }

    private static func formatVTTTime(_ seconds: Double) -> String {
        formatTime(seconds, millisecondSeparator: ".")
    }

    private static func formatTime(_ seconds: Double, millisecondSeparator: String) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, millisecondSeparator, milliseconds)
    }
}

enum SubtitleCueBuilder {
    static func cues(text: String, duration: Double, words: [WordTimingOutput]) -> [SegmentTimingOutput] {
        guard !words.isEmpty else {
            return text.isEmpty ? [] : [SegmentTimingOutput(startTime: 0, endTime: duration, text: text)]
        }

        var cues: [SegmentTimingOutput] = []
        var currentWords: [WordTimingOutput] = []
        let maxWords = 12
        let maxDuration = 6.0

        func flush() {
            guard let first = currentWords.first, let last = currentWords.last else { return }
            let cueText = currentWords.map(\.word).joined(separator: " ")
            cues.append(SegmentTimingOutput(startTime: first.startTime, endTime: last.endTime, text: cueText))
            currentWords.removeAll()
        }

        for word in words {
            if let first = currentWords.first {
                let wouldExceedDuration = word.endTime - first.startTime >= maxDuration
                let wouldExceedWords = currentWords.count >= maxWords
                if wouldExceedDuration || wouldExceedWords {
                    flush()
                }
            }
            currentWords.append(word)
        }
        flush()

        return cues
    }
}
