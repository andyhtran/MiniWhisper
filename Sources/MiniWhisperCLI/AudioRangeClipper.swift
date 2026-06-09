import AVFoundation
import Foundation

struct AudioRangeRequest {
    var from: Double?
    var to: Double?
    var offset: Double?
    var duration: Double?

    var isEmpty: Bool {
        from == nil && to == nil && offset == nil && duration == nil
    }

    func resolved(totalDuration: Double) throws -> TranscriptionRangeOutput? {
        guard !isEmpty else { return nil }

        if from != nil && offset != nil {
            throw CLIError.usage("Use either `--from` or `--offset`, not both.")
        }
        if to != nil && duration != nil {
            throw CLIError.usage("Use either `--to` or `--duration`, not both.")
        }

        let start = from ?? offset ?? 0
        let end: Double
        if let to {
            end = to
        } else if let duration {
            end = start + duration
        } else {
            end = totalDuration
        }

        guard start >= 0 else {
            throw CLIError.usage("Range start must be >= 0.")
        }
        guard end > start else {
            throw CLIError.usage("Range end must be greater than range start.")
        }
        guard start < totalDuration else {
            throw CLIError.usage("Range start is beyond the audio duration (\(format(totalDuration))s).")
        }

        let clampedEnd = min(end, totalDuration)
        return TranscriptionRangeOutput(
            startSeconds: start,
            endSeconds: clampedEnd,
            durationSeconds: clampedEnd - start
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct PreparedAudio {
    let url: URL
    let range: TranscriptionRangeOutput?
    let isTemporary: Bool
}

enum AudioRangeClipper {
    static func prepare(audioURL: URL, range request: AudioRangeRequest) throws -> PreparedAudio {
        guard !request.isEmpty else {
            return PreparedAudio(url: audioURL, range: nil, isTemporary: false)
        }

        let input = try AVAudioFile(forReading: audioURL)
        let sampleRate = input.processingFormat.sampleRate
        let totalDuration = Double(input.length) / sampleRate
        guard let range = try request.resolved(totalDuration: totalDuration) else {
            return PreparedAudio(url: audioURL, range: nil, isTemporary: false)
        }

        let startFrame = AVAudioFramePosition((range.startSeconds * sampleRate).rounded())
        let frameCount = AVAudioFrameCount((range.durationSeconds * sampleRate).rounded())
        input.framePosition = startFrame

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniwhispercli_range_\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: tempURL, settings: input.processingFormat.settings)

        var remaining = frameCount
        while remaining > 0 {
            let capacity = min(remaining, 4096)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity) else {
                throw CLIError.runtime("Failed to allocate audio range buffer.")
            }
            try input.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }

        return PreparedAudio(url: tempURL, range: range, isTemporary: true)
    }

    static func cleanup(_ prepared: PreparedAudio) {
        guard prepared.isTemporary else { return }
        try? FileManager.default.removeItem(at: prepared.url)
    }
}

enum TimeArgumentParser {
    static func parse(_ value: String, option: String) throws -> Double {
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3 else {
                throw CLIError.usage("Invalid time for \(option): \(value). Use seconds, MM:SS, or HH:MM:SS.")
            }

            let numbers = try parts.map { part -> Double in
                guard let number = Double(part) else {
                    throw CLIError.usage("Invalid time for \(option): \(value).")
                }
                return number
            }

            if numbers.contains(where: { $0 < 0 }) {
                throw CLIError.usage("Invalid time for \(option): \(value). Time values must be >= 0.")
            }

            if numbers.count == 2 {
                return numbers[0] * 60 + numbers[1]
            }
            return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        }

        guard let seconds = Double(value), seconds >= 0 else {
            throw CLIError.usage("Invalid time for \(option): \(value). Use seconds, MM:SS, or HH:MM:SS.")
        }
        return seconds
    }
}
