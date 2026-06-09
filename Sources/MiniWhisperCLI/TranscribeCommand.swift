import AVFoundation
import Foundation
@preconcurrency import FluidAudio

enum TranscribeModelChoice: String, Encodable {
    case parakeet
    case whisper
}

enum SourceChoice: String, Encodable {
    case microphone
    case system

    var fluidAudioSource: AudioSource {
        switch self {
        case .microphone: return .microphone
        case .system: return .system
        }
    }
}

struct TranscribeOptions {
    var audioPath: String?
    var model: TranscribeModelChoice = .parakeet
    var source: SourceChoice = .microphone
    var sourceSpecified = false
    var whisperLanguage: WhisperLanguageChoice = .auto
    var whisperLanguageSpecified = false
    var forceStreaming = false
    var timestampMode: TimestampMode = .none
    var legacyWordTimestamps = false
    var metadata = false
    var outputFormat: OutputFormat = .text
    var outputFormatSpecified = false
    var outputPath: String?
    var outputJSONPath: String?
    var outputSRTPath: String?
    var outputVTTPath: String?
    var range = AudioRangeRequest()
    var quiet = false
}

struct TranscriptionJSONOutput: Encodable {
    let audioFile: String
    let range: TranscriptionRangeOutput?
    let engine: String
    let mode: String
    let modelVersion: String
    let model: String
    let source: String
    let language: String
    let text: String
    let durationSeconds: Double
    let processingTimeSeconds: Double
    let rtfx: Double
    let confidence: Float
    let confidenceAvailable: Bool
    let segments: [SegmentTimingOutput]
    // Internal cue source for SRT/VTT sidecars; JSON timestamp output is gated
    // by `segments` so `--timestamps none` can still emit subtitle files.
    let subtitleSegments: [SegmentTimingOutput]
    let wordTimings: [WordTimingOutput]
    let timingsConfirmed: Bool?

    enum CodingKeys: String, CodingKey {
        case audioFile = "audio_file"
        case range
        case engine
        case mode
        case modelVersion = "model_version"
        case model
        case source
        case language
        case text
        case durationSeconds = "duration_seconds"
        case processingTimeSeconds = "processing_time_seconds"
        case rtfx
        case confidence
        case confidenceAvailable = "confidence_available"
        case segments
        case wordTimings = "word_timings"
        case timingsConfirmed = "timings_confirmed"
    }
}

struct WordTimingOutput: Encodable {
    let word: String
    let startTime: Double
    let endTime: Double
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case word
        case startTime = "start_time"
        case endTime = "end_time"
        case confidence
    }
}

enum TranscribeCommand {
    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try parse(arguments: arguments)
            return try await transcribe(options: options)
        } catch CLIExit.success {
            return 0
        } catch CLIError.usage(let message) {
            Console.error(message)
            Console.error("Run `miniwhispercli transcribe --help` for usage.")
            return 2
        } catch {
            Console.error(error.localizedDescription)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> TranscribeOptions {
        guard !arguments.contains("-h"), !arguments.contains("--help") else {
            Help.printTranscribe()
            throw CLIExit.success
        }

        var options = TranscribeOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--model":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let model = TranscribeModelChoice(rawValue: value) else {
                    throw CLIError.usage("Invalid model: \(value). Expected parakeet or whisper.")
                }
                options.model = model
            case "--source":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let source = SourceChoice(rawValue: value) else {
                    throw CLIError.usage("Invalid source: \(value). Expected microphone or system.")
                }
                options.source = source
                options.sourceSpecified = true
            case "--language":
                let value = try value(after: argument, in: arguments, at: &index)
                options.whisperLanguage = try WhisperLanguageChoice.parse(value)
                options.whisperLanguageSpecified = true
            case "--streaming":
                options.forceStreaming = true
            case "--word-timestamps":
                options.timestampMode = .word
                options.legacyWordTimestamps = true
            case "--timestamps":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let mode = TimestampMode(rawValue: value) else {
                    throw CLIError.usage("Invalid timestamps mode: \(value). Expected none, segment, or word.")
                }
                options.timestampMode = mode
            case "--metadata":
                options.metadata = true
            case "--json":
                options.outputFormat = .json
                options.outputFormatSpecified = true
            case "--format":
                let value = try value(after: argument, in: arguments, at: &index)
                guard let format = OutputFormat(rawValue: value) else {
                    throw CLIError.usage("Invalid format: \(value). Expected text, json, srt, or vtt.")
                }
                options.outputFormat = format
                options.outputFormatSpecified = true
            case "-o", "--output":
                options.outputPath = try value(after: argument, in: arguments, at: &index)
            case "--output-json":
                options.outputJSONPath = try value(after: argument, in: arguments, at: &index)
            case "--output-srt":
                options.outputSRTPath = try value(after: argument, in: arguments, at: &index)
            case "--output-vtt":
                options.outputVTTPath = try value(after: argument, in: arguments, at: &index)
            case "--from":
                options.range.from = try TimeArgumentParser.parse(
                    value(after: argument, in: arguments, at: &index),
                    option: argument
                )
            case "--to":
                options.range.to = try TimeArgumentParser.parse(
                    value(after: argument, in: arguments, at: &index),
                    option: argument
                )
            case "--offset":
                options.range.offset = try TimeArgumentParser.parse(
                    value(after: argument, in: arguments, at: &index),
                    option: argument
                )
            case "--duration":
                options.range.duration = try TimeArgumentParser.parse(
                    value(after: argument, in: arguments, at: &index),
                    option: argument
                )
            case "--quiet":
                options.quiet = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown transcribe option: \(argument)")
                }
                if options.audioPath != nil {
                    throw CLIError.usage("Only one audio file can be transcribed at a time.")
                }
                options.audioPath = argument
            }

            index += 1
        }

        guard options.audioPath != nil else {
            throw CLIError.usage("Missing audio file.")
        }

        if let outputPath = options.outputPath,
           !options.outputFormatSpecified,
           let inferred = OutputFormat.infer(from: outputPath) {
            options.outputFormat = inferred
        }

        switch options.model {
        case .parakeet:
            if options.whisperLanguageSpecified {
                throw CLIError.usage("`--language` applies only to `--model whisper`.")
            }
        case .whisper:
            if options.sourceSpecified {
                throw CLIError.usage("`--source` applies only to `--model parakeet`.")
            }
            if options.forceStreaming {
                throw CLIError.usage("`--streaming` applies only to `--model parakeet`.")
            }
        }

        return options
    }

    private static func transcribe(options: TranscribeOptions) async throws -> Int32 {
        guard let audioPath = options.audioPath else {
            throw CLIError.usage("Missing audio file.")
        }

        let audioURL = PathResolver.fileURL(for: audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CLIError.runtime("Audio file not found: \(audioURL.path)")
        }

        let preparedAudio = try AudioRangeClipper.prepare(audioURL: audioURL, range: options.range)
        defer { AudioRangeClipper.cleanup(preparedAudio) }

        let output: TranscriptionJSONOutput
        switch options.model {
        case .parakeet:
            output = try await transcribeWithParakeet(
                audioURL: preparedAudio.url,
                displayAudioURL: audioURL,
                range: preparedAudio.range,
                options: options
            )
        case .whisper:
            output = try await transcribeWithWhisper(
                audioURL: preparedAudio.url,
                displayAudioURL: audioURL,
                range: preparedAudio.range,
                options: options
            )
        }

        let primary = try TranscribeRenderer.render(output, format: options.outputFormat)
        if let outputPath = options.outputPath {
            try TextFileWriter.write(primary, to: outputPath)
            if !options.quiet {
                Console.error("Output written to \(PathResolver.fileURL(for: outputPath).path)")
            }
        } else {
            Console.write(primary)
        }

        if let outputJSONPath = options.outputJSONPath {
            try JSONPrinter.write(output, to: outputJSONPath)
            if !options.quiet {
                Console.error("JSON written to \(PathResolver.fileURL(for: outputJSONPath).path)")
            }
        }

        if let outputSRTPath = options.outputSRTPath {
            try TextFileWriter.write(try TranscribeRenderer.render(output, format: .srt), to: outputSRTPath)
            if !options.quiet {
                Console.error("SRT written to \(PathResolver.fileURL(for: outputSRTPath).path)")
            }
        }

        if let outputVTTPath = options.outputVTTPath {
            try TextFileWriter.write(try TranscribeRenderer.render(output, format: .vtt), to: outputVTTPath)
            if !options.quiet {
                Console.error("VTT written to \(PathResolver.fileURL(for: outputVTTPath).path)")
            }
        }

        if options.legacyWordTimestamps {
            printWordTimings(output.wordTimings)
        }

        if options.metadata {
            printMetadata(output: output)
        }

        return 0
    }

    private static func transcribeWithParakeet(
        audioURL: URL,
        displayAudioURL: URL,
        range: TranscriptionRangeOutput?,
        options: TranscribeOptions
    ) async throws -> TranscriptionJSONOutput {
        let modelDirectory = ParakeetModel.directory
        let modelInstalled = AsrModels.modelsExist(at: modelDirectory, version: ParakeetModel.version)
        if !options.quiet {
            Console.error(modelInstalled
                ? "Loading \(ParakeetModel.modelName)..."
                : "Downloading \(ParakeetModel.modelName) to \(modelDirectory.path)...")
        }

        let models = try await AsrModels.downloadAndLoad(version: ParakeetModel.version)
        let manager = AsrManager(config: .default)

        do {
            try await manager.initialize(models: models)

            if !options.quiet {
                let mode = options.forceStreaming ? "streaming" : "batch"
                Console.error("Transcribing \(audioURL.path) (\(mode), model: parakeet, source: \(options.source.rawValue))...")
            }

            let wallClockStart = Date()
            let result: ASRResult
            if options.forceStreaming {
                result = try await manager.transcribeStreaming(audioURL, source: options.source.fluidAudioSource)
            } else {
                result = try await manager.transcribe(audioURL, source: options.source.fluidAudioSource)
            }
            let wallClockProcessingTime = Date().timeIntervalSince(wallClockStart)
            await manager.cleanup()

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = AudioMetadata.durationSeconds(for: audioURL) ?? result.duration
            let processingTime = result.processingTime > 0 ? result.processingTime : wallClockProcessingTime
            let wordTimings = WordTimingMerger.mergeTokensIntoWords(result.tokenTimings ?? [])
            let subtitleSegments = SubtitleCueBuilder.cues(text: text, duration: duration, words: wordTimings)
            let jsonSegments = options.timestampMode == .segment || options.timestampMode == .word
                ? subtitleSegments
                : []
            let jsonWordTimings = options.timestampMode == .word ? wordTimings : []

            return TranscriptionJSONOutput(
                audioFile: displayAudioURL.path,
                range: range,
                engine: TranscribeModelChoice.parakeet.rawValue,
                mode: options.forceStreaming ? "streaming" : "batch",
                modelVersion: ParakeetModel.versionName,
                model: ParakeetModel.modelName,
                source: options.source.rawValue,
                language: "auto",
                text: text,
                durationSeconds: duration,
                processingTimeSeconds: processingTime,
                rtfx: processingTime > 0 ? duration / processingTime : 0,
                confidence: result.confidence,
                confidenceAvailable: true,
                segments: jsonSegments,
                subtitleSegments: subtitleSegments,
                wordTimings: jsonWordTimings,
                timingsConfirmed: nil
            )
        } catch {
            await manager.cleanup()
            throw error
        }
    }

    private static func transcribeWithWhisper(
        audioURL: URL,
        displayAudioURL: URL,
        range: TranscriptionRangeOutput?,
        options: TranscribeOptions
    ) async throws -> TranscriptionJSONOutput {
        let result = try await WhisperCLITranscriber.transcribe(
            audioURL: audioURL,
            language: options.whisperLanguage,
            quiet: options.quiet
        )

        return TranscriptionJSONOutput(
            audioFile: displayAudioURL.path,
            range: range,
            engine: TranscribeModelChoice.whisper.rawValue,
            mode: "batch",
            modelVersion: "large-v3-turbo",
            model: result.model,
            source: "file",
            language: result.language,
            text: result.text,
            durationSeconds: result.audioDuration,
            processingTimeSeconds: result.processingTime,
            rtfx: result.processingTime > 0 ? result.audioDuration / result.processingTime : 0,
            confidence: 0,
            confidenceAvailable: false,
            segments: options.timestampMode == .segment || options.timestampMode == .word
                ? result.segments
                : [],
            subtitleSegments: result.segments,
            wordTimings: [],
            timingsConfirmed: nil
        )
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError.usage("Missing value for \(option).")
        }

        index = valueIndex
        return arguments[valueIndex]
    }

    private static func printWordTimings(_ timings: [WordTimingOutput]) {
        guard !timings.isEmpty else {
            Console.error("Word-level timestamps: unavailable")
            return
        }

        Console.error("Word-level timestamps:")
        for (index, timing) in timings.enumerated() {
            let confidence = format(Double(timing.confidence))
            Console.error(
                "  [\(index)] \(format(timing.startTime))s - \(format(timing.endTime))s: \"\(timing.word)\" (conf: \(confidence))"
            )
        }
    }

    private static func printMetadata(output: TranscriptionJSONOutput) {
        Console.error("Metadata:")
        Console.error("  Audio: \(output.audioFile)")
        Console.error("  Engine: \(output.engine)")
        Console.error("  Mode: \(output.mode)")
        Console.error("  Model: \(output.model)")
        Console.error("  Source: \(output.source)")
        Console.error("  Language: \(output.language)")
        Console.error("  Duration: \(format(output.durationSeconds))s")
        Console.error("  Processing: \(format(output.processingTimeSeconds))s")
        Console.error("  RTFx: \(format(output.rtfx))")
        Console.error("  Confidence: \(output.confidenceAvailable ? format(Double(output.confidence)) : "unavailable")")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum CLIExit: Error {
    case success
}

enum AudioMetadata {
    static func durationSeconds(for url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }

        return Double(file.length) / file.processingFormat.sampleRate
    }
}

enum WordTimingMerger {
    static func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTimingOutput] {
        guard !tokenTimings.isEmpty else { return [] }

        var words: [WordTimingOutput] = []
        var currentWord = ""
        var currentStart: Double?
        var currentEnd = 0.0
        var confidences: [Float] = []

        for timing in tokenTimings {
            let token = timing.token
            let startsNewWord = token.hasPrefix(" ")
                || token.hasPrefix("\n")
                || token.hasPrefix("\t")
                || token.hasPrefix("▁")

            if startsNewWord, !currentWord.isEmpty, let start = currentStart {
                words.append(
                    WordTimingOutput(
                        word: currentWord,
                        startTime: start,
                        endTime: currentEnd,
                        confidence: average(confidences)
                    )
                )
                currentWord = ""
                confidences = []
            }

            let cleanToken = token.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t▁"))
            if currentStart == nil || currentWord.isEmpty {
                currentStart = timing.startTime
            }
            currentWord += cleanToken
            currentEnd = timing.endTime
            confidences.append(timing.confidence)
        }

        if !currentWord.isEmpty, let start = currentStart {
            words.append(
                WordTimingOutput(
                    word: currentWord,
                    startTime: start,
                    endTime: currentEnd,
                    confidence: average(confidences)
                )
            )
        }

        return words
    }

    private static func average(_ confidences: [Float]) -> Float {
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Float(confidences.count)
    }
}
