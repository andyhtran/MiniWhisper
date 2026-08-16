import Foundation
@preconcurrency import FluidAudio

/// Speaker diarization: who spoke when, without transcribing.
///
/// Emits RTTM because that is the interchange format diarization tooling reads,
/// and it joins cleanly against a separate transcript on timestamps.
enum DiarizeCommand {
    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try DiarizeOptions.parse(arguments)
            if options.showHelp {
                Help.printDiarize()
                return 0
            }
            return try await execute(options)
        } catch let error as CLIError {
            Console.error(error.errorDescription ?? "Invalid arguments.")
            return 2
        } catch {
            Console.error("Diarization failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func execute(_ options: DiarizeOptions) async throws -> Int32 {
        let audioURL = PathResolver.fileURL(for: options.audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CLIError.runtime("Audio file not found: \(audioURL.path)")
        }

        let samples = try WhisperCLITranscriber.resampleTo16kHz(
            audioURL: audioURL, channel: options.channel)
        guard !samples.isEmpty else {
            throw CLIError.runtime("Audio file decoded to zero samples: \(audioURL.path)")
        }
        let duration = Double(samples.count) / 16_000

        // DiarizerManager ignores numSpeakers; OfflineDiarizerManager honours it.
        var config = OfflineDiarizerConfig.default
        if let threshold = options.clusteringThreshold {
            config.clustering.threshold = Double(threshold)
        }
        if let speakers = options.numSpeakers {
            config.clustering.numSpeakers = speakers
        }

        if !options.quiet {
            Console.error("Loading diarizer models...")
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()

        if !options.quiet {
            let target = options.numSpeakers.map(String.init) ?? "auto"
            Console.error(
                "Diarizing \(audioURL.lastPathComponent) "
                + "(\(String(format: "%.1f", duration))s, speakers: \(target))...")
        }

        let started = Date()
        let result = try await manager.process(audio: samples)
        let elapsed = Date().timeIntervalSince(started)

        // RTTM identifies segments by recording id, not by path.
        let recordingID = audioURL.deletingPathExtension().lastPathComponent
        let rttm = renderRTTM(segments: result.segments, recordingID: recordingID)

        if let output = options.outputPath {
            try TextFileWriter.write(rttm, to: output)
            if !options.quiet {
                Console.error("Wrote \(result.segments.count) segments to \(output)")
            }
        } else {
            Console.write(rttm)
        }

        if !options.quiet {
            let speakers = Set(result.segments.map(\.speakerId)).count
            let speech = result.segments.reduce(0.0) { $0 + Double($1.durationSeconds) }
            Console.error(
                "\(speakers) speakers, \(result.segments.count) segments, "
                + "\(String(format: "%.1f", speech))s speech in "
                + "\(String(format: "%.1f", elapsed))s "
                + "(\(String(format: "%.0f", duration / max(elapsed, 0.001)))x realtime)")
        }

        return 0
    }

    /// NIST RTTM: ten space-separated fields, one SPEAKER line per segment.
    /// Field 4 is onset and field 5 is duration, both in seconds — not an end time.
    static func renderRTTM(segments: [TimedSpeakerSegment], recordingID: String) -> String {
        var lines: [String] = []
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let start = String(format: "%.3f", segment.startTimeSeconds)
            let duration = String(format: "%.3f", segment.durationSeconds)
            lines.append(
                "SPEAKER \(recordingID) 1 \(start) \(duration) <NA> <NA> \(segment.speakerId) <NA> <NA>")
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

struct DiarizeOptions {
    var audioPath: String = ""
    var outputPath: String?
    var numSpeakers: Int?
    var clusteringThreshold: Float?
    var channel: AudioChannelSelection = .mix
    var quiet: Bool = false
    var showHelp: Bool = false

    static func parse(_ arguments: [String]) throws -> DiarizeOptions {
        var options = DiarizeOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
                return options
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.runtime("Missing value for \(argument).")
                }
                options.outputPath = arguments[index]
            case "--speakers":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError.runtime("--speakers needs a positive integer.")
                }
                options.numSpeakers = value
            case "--threshold":
                index += 1
                guard index < arguments.count, let value = Float(arguments[index]) else {
                    throw CLIError.runtime("--threshold needs a number.")
                }
                options.clusteringThreshold = value
            case "--channel":
                index += 1
                guard index < arguments.count,
                      let channel = AudioChannelSelection.parse(arguments[index]) else {
                    throw CLIError.runtime("--channel needs mix or a channel index like 0 or 1.")
                }
                options.channel = channel
            case "-q", "--quiet":
                options.quiet = true
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIError.runtime("Unknown option: \(argument)")
                }
                guard options.audioPath.isEmpty else {
                    throw CLIError.runtime("Unexpected extra argument: \(argument)")
                }
                options.audioPath = argument
            }
            index += 1
        }

        if options.audioPath.isEmpty && !options.showHelp {
            throw CLIError.runtime("Missing audio file. Run `miniwhispercli diarize --help`.")
        }
        return options
    }
}
