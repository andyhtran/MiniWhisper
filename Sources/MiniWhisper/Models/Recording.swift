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
    /// Which transcription pathway produced this recording — the raw value
    /// of `TranscriptionMode` (`english` / `multilingual` / `custom`).
    /// Authoritative source for history's friendly label; without it the UI
    /// has to guess from the model string and gets it wrong when a custom
    /// endpoint hosts a model whose name starts with `whisper-`. Optional
    /// so legacy metadata.json files still decode.
    var provider: String?
}

/// Metadata captured for a voice-driven edit-mode invocation. The audio
/// + voice-instruction transcript live on the parent `Recording`; this
/// holds the bits unique to the edit step: what text the user had
/// selected, what the backend produced, and which CLI/model ran the
/// edit. `backendModel` is stored as a free-form string so future
/// per-provider model overrides remain captured in history without
/// schema churn. `editDuration` is the wall-clock latency of the CLI
/// call itself — surfaced in history so the user can compare model
/// speed at a glance. Optional for older recordings predating it.
struct RecordingEditMode: Codable, Equatable, Hashable, Sendable {
    let originalSelection: String
    let editedResult: String
    let backend: String
    let backendDisplayName: String
    let backendModel: String
    var editDuration: TimeInterval?

    init(
        originalSelection: String,
        editedResult: String,
        backend: String,
        backendDisplayName: String,
        backendModel: String,
        editDuration: TimeInterval? = nil
    ) {
        self.originalSelection = originalSelection
        self.editedResult = editedResult
        self.backend = backend
        self.backendDisplayName = backendDisplayName
        self.backendModel = backendModel
        self.editDuration = editDuration
    }
}

/// Metadata for an auto-cleanup pass on a normal recording. The final
/// inserted text lives on `Recording.transcription.text`; this struct
/// captures the pre-cleanup version + which model produced the polish
/// + how long it took, so the user can compare and re-paste the raw
/// transcript from history if cleanup over-edited.
struct RecordingCleanup: Codable, Equatable, Hashable, Sendable {
    let rawText: String
    let cleanedText: String
    let backendModel: String
    var cleanupDuration: TimeInterval?

    init(
        rawText: String,
        cleanedText: String,
        backendModel: String,
        cleanupDuration: TimeInterval? = nil
    ) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.backendModel = backendModel
        self.cleanupDuration = cleanupDuration
    }
}

struct Recording: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let createdAt: Date
    let recording: RecordingInfo
    var transcription: RecordingTranscription?
    let configuration: RecordingConfiguration
    var status: RecordingStatus
    /// Present only for entries created by the edit-selection shortcut.
    /// `nil` for normal voice-transcription entries.
    var editMode: RecordingEditMode?
    /// Present when the auto-cleanup pass ran on this recording. `nil`
    /// when auto-cleanup is off or skipped (empty transcript, error
    /// fallback). Stored alongside `transcription` so the user can see
    /// what was changed.
    var cleanup: RecordingCleanup?
    /// File name of the audio inside `storageDirectory`. `nil` decodes
    /// from older metadata where audio was always `audio.wav`. Updated
    /// to `audio.caf` after the retention sweep compresses a WAV that
    /// has aged past the WAV-retention window.
    var audioFileName: String?

    init(
        id: String,
        createdAt: Date,
        recording: RecordingInfo,
        transcription: RecordingTranscription?,
        configuration: RecordingConfiguration,
        status: RecordingStatus = .completed,
        editMode: RecordingEditMode? = nil,
        cleanup: RecordingCleanup? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.recording = recording
        self.transcription = transcription
        self.configuration = configuration
        self.status = status
        self.editMode = editMode
        self.cleanup = cleanup
        self.audioFileName = audioFileName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case recording
        case transcription
        case configuration
        case status
        case editMode
        case cleanup
        case audioFileName
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
        editMode = try container.decodeIfPresent(RecordingEditMode.self, forKey: .editMode)
        cleanup = try container.decodeIfPresent(RecordingCleanup.self, forKey: .cleanup)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
    }

    /// Path to the on-disk audio file. Resolves to `audio.wav` for
    /// freshly recorded entries (and any legacy metadata that predates
    /// the `audioFileName` field) and `audio.caf` after retention
    /// compresses the WAV.
    var audioURL: URL {
        storageDirectory.appendingPathComponent(audioFileName ?? "audio.wav")
    }

    /// Where the compressed copy lives. Used by the retention sweep
    /// when transitioning a recording from WAV to CAF.
    var compressedAudioURL: URL {
        storageDirectory.appendingPathComponent("audio.caf")
    }

    /// True when the audio is the lossless WAV original. Re-transcribe
    /// paths can use it directly; CAF needs to be decoded to a temp
    /// WAV first.
    var isAudioLossless: Bool {
        let name = audioFileName ?? "audio.wav"
        return name.hasSuffix(".wav")
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
    /// (before the 15-minute retention cleanup). Edit-mode entries are
    /// excluded — their audio is a spoken instruction, not content the
    /// user would want to re-transcribe in its own right.
    var canRetranscribeAsNew: Bool {
        status == .completed && transcription != nil && hasAudioFile && editMode == nil
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
