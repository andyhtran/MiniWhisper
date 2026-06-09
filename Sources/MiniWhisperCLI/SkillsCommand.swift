import Foundation

enum CoreSkill {
    static let directoryName = "miniwhisper-core"
    static let managedMarkerFileName = ".miniwhisper-managed-skill"
    static let managedMarkerText = "miniwhispercli managed discovery stub\n"

    static let discoveryStub =
        """
        ---
        name: miniwhisper-core
        description: Use MiniWhisper CLI for local audio transcription with Parakeet or Whisper. Use when the user asks to transcribe a local audio file with MiniWhisper, Parakeet, Whisper, or local multilingual speech-to-text.
        ---

        # MiniWhisper Core

        Use MiniWhisper CLI when the user asks to transcribe a local audio file with MiniWhisper, Parakeet, or local Whisper.

        Before transcribing, run:

        `miniwhispercli skills get core`

        That command prints the version-matched workflow for the installed CLI, including when to choose Parakeet versus Whisper.
        """

    static let text =
        """
        # MiniWhisper Core

        Use MiniWhisper CLI when the user asks to transcribe a local audio file with MiniWhisper, Parakeet, or local Whisper.

        ## Core Workflow

        1. Confirm the audio file path exists before running transcription.
        2. Choose the model from the language and user request.
        3. Choose the output shape based on the requested artifact.
        4. Run `miniwhispercli transcribe <audio>` with the smallest flag set that satisfies the request.
        5. Use the diagnostics/setup commands only if transcription fails or model readiness is uncertain.

        ## Model Routing

        Default to Parakeet v3:

        - Use `miniwhispercli transcribe <audio>` for English and supported European languages.
        - Parakeet v3 is the fast default and supports 25 European languages with automatic language detection.
        - If Parakeet is missing, `miniwhispercli models install parakeet` installs it. First transcription also downloads it automatically.

        Use Whisper when broader language coverage matters:

        - Use `miniwhispercli transcribe <audio> --model whisper` for non-European languages or when the user asks for multilingual/broad language coverage.
        - Whisper uses `whisper-large-v3-turbo` through whisper.cpp and defaults to `--language auto`.
        - Pass `--language <code>` only when the user gives a known language and wants to avoid auto-detection.
        - If Whisper is missing, `miniwhispercli models install whisper` installs the model and VAD helper. First Whisper transcription also downloads them automatically.

        ## Transcription Choices

        - Plain transcript for chat or clipboard use:
          `miniwhispercli transcribe <audio>`
        - Non-European or broad multilingual transcription:
          `miniwhispercli transcribe <audio> --model whisper`
        - Structured result for agent parsing:
          `miniwhispercli transcribe <audio> --format json`
        - Save structured result as an artifact:
          `miniwhispercli transcribe <audio> --format json -o <file> --quiet`
        - Include word timings and performance details:
          `miniwhispercli transcribe <audio> --timestamps word --metadata --format json -o <file>`
        - Transcribe only part of a longer file:
          `miniwhispercli transcribe <audio> --from 01:20 --duration 50`
        - Save subtitles:
          `miniwhispercli transcribe <audio> --format srt -o <file>`

        ## Advanced Source Flag

        `--source` is Parakeet-only. It does not choose an input device and does not capture audio. The CLI always transcribes the file path passed to `transcribe`.

        - `--source microphone` is the default and matches MiniWhisper app behavior.
        - `--source system` matches FluidAudio's file-transcription default more closely.

        Do not change `--source` unless comparing MiniWhisper output against FluidAudio behavior. Do not pass `--source` with `--model whisper`.

        ## Output Rules

        Treat stdout as the user-requested artifact. Progress, word timings, metadata, and diagnostics are stderr-only unless `--json` is explicitly requested.
        Use `--json` when the agent needs the structured result on stdout.
        Prefer `--format json -o <file> --quiet` when creating a JSON artifact.
        `--output-json <file>` is a compatibility sidecar that also writes JSON while preserving the primary output.
        Native transcription libraries may still emit diagnostics to stderr; do not parse stderr as transcript content.

        Use `--timestamps segment` or `--timestamps word` for clean timestamp data in JSON. Avoid `--word-timestamps` unless the user specifically wants the legacy stderr dump.

        Use `--format srt` or `--format vtt` for subtitle artifacts. `--output-srt <file>` and `--output-vtt <file>` can create subtitle sidecars while keeping the primary output as text or JSON.

        Time ranges accept seconds, `MM:SS`, or `HH:MM:SS`:

        - `--from 01:20 --to 02:10`
        - `--offset 80 --duration 50`

        JSON output has this shape:

        ```json
        {
          "audio_file": "/path/to/audio.wav",
          "engine": "parakeet",
          "mode": "batch",
          "model_version": "v3",
          "model": "parakeet-tdt-v3",
          "source": "microphone",
          "language": "auto",
          "range": null,
          "text": "transcribed text",
          "duration_seconds": 3.2,
          "processing_time_seconds": 0.6,
          "rtfx": 5.3,
          "confidence": 0.97,
          "confidence_available": true,
          "segments": [],
          "word_timings": []
        }
        ```

        ## Diagnostics And Setup

        Use these only when setup is uncertain or a transcription command fails:

        - `miniwhispercli models status --json` checks installed model readiness.
        - `miniwhispercli models install parakeet` installs the default fast local model.
        - `miniwhispercli models install whisper` installs optional broad multilingual support.
        - `miniwhispercli doctor --json` checks local environment problems.
        - `miniwhispercli transcribe --help` shows the full flag list when a needed option is unclear.
        """
}

enum SkillsCommand {
    static func run(arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            printHelp()
            return 0
        }

        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "-h", "--help", "help":
            printHelp()
            return 0
        case "list":
            return list(arguments: rest)
        case "get":
            return get(arguments: rest)
        default:
            Console.error("Unknown skills command: \(subcommand)")
            return 2
        }
    }

    private static func list(arguments: [String]) -> Int32 {
        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown skills list option: \(unknown)")
            return 2
        }

        if emitJSON {
            Console.out("{\"skills\":[\"core\"]}")
        } else {
            Console.out("core")
        }
        return 0
    }

    private static func get(arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            Console.error("Usage: miniwhispercli skills get core")
            return 2
        }

        guard arguments[0] == "core" else {
            Console.error("Unknown skill: \(arguments[0])")
            return 2
        }

        Console.out(CoreSkill.text)
        return 0
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              miniwhispercli skills list [--json]
              miniwhispercli skills get core
            """
        )
    }
}

enum SkillCommand {
    static func run(arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            return status(arguments: [])
        }

        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "-h", "--help", "help":
            printHelp()
            return 0
        case "status":
            return status(arguments: rest)
        case "install":
            return install(arguments: rest)
        case "uninstall":
            return uninstall(arguments: rest)
        default:
            Console.error("Unknown skill command: \(subcommand)")
            return 2
        }
    }

    private static func status(arguments: [String]) -> Int32 {
        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown skill status option: \(unknown)")
            return 2
        }

        let status = SkillStatus.current()
        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: status))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        Console.out(
            """
            MiniWhisper skill status

            Target: \(status.target)
            Strategy: \(status.strategy)
            Skill path: \(status.skillPath)
            State: \(status.state)
            Repairable: \(status.repairable ? "yes" : "no")
            Runtime guidance: \(status.runtimeGuidanceCommand)

            Next:
              \(status.nextCommand)
            """
        )
        return 0
    }

    private static func install(arguments: [String]) -> Int32 {
        guard arguments.isEmpty else {
            Console.error("Usage: miniwhispercli skill install")
            return 2
        }

        do {
            try SkillInstaller.install()
            Console.out("Installed MiniWhisper core discovery skill.")
            Console.out("Claude skill: \(MiniWhisperPaths.coreSkillClaudeInstall.path)")
            Console.out("Runtime guidance: miniwhispercli skills get core")
            return 0
        } catch {
            Console.error(error.localizedDescription)
            return 1
        }
    }

    private static func uninstall(arguments: [String]) -> Int32 {
        guard arguments.isEmpty else {
            Console.error("Usage: miniwhispercli skill uninstall")
            return 2
        }

        do {
            try SkillInstaller.uninstall()
            Console.out("Uninstalled MiniWhisper core skill.")
            return 0
        } catch {
            Console.error(error.localizedDescription)
            return 1
        }
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              miniwhispercli skill
              miniwhispercli skill status [--json]
              miniwhispercli skill install
              miniwhispercli skill uninstall

            Installs a managed Claude Code discovery stub at:
              \(MiniWhisperPaths.coreSkillClaudeInstall.path)
            """
        )
    }
}

struct SkillStatus: Encodable {
    let target: String
    let strategy: String
    let skillPath: String
    let markerPath: String
    let state: String
    let installed: Bool
    let repairable: Bool
    let needsRefresh: Bool
    let runtimeGuidanceCommand: String

    enum CodingKeys: String, CodingKey {
        case target
        case strategy
        case skillPath = "skill_path"
        case markerPath = "marker_path"
        case state
        case installed
        case repairable
        case needsRefresh = "needs_refresh"
        case runtimeGuidanceCommand = "runtime_guidance_command"
    }

    static func current() -> SkillStatus {
        let installURL = MiniWhisperPaths.coreSkillClaudeInstall
        let state = SkillInstallState.current(at: installURL)
        return SkillStatus(
            target: "Claude Code",
            strategy: "managed_discovery_stub",
            skillPath: installURL.path,
            markerPath: installURL.appendingPathComponent(CoreSkill.managedMarkerFileName).path,
            state: state.rawValue,
            installed: state.installed,
            repairable: state.repairable,
            needsRefresh: state.needsRefresh,
            runtimeGuidanceCommand: "miniwhispercli skills get core"
        )
    }

    var nextCommand: String {
        if !repairable {
            return "Move the existing skill path, then run `miniwhispercli skill install`."
        }
        if !installed || needsRefresh {
            return "miniwhispercli skill install"
        }
        return "miniwhispercli skills get core"
    }
}

private enum SkillInstallState: String {
    case missing
    case managedStub = "managed_stub"
    case staleManagedStub = "stale_managed_stub"
    case legacySymlink = "legacy_symlink"
    case foreignSymlink = "foreign_symlink"
    case foreignPath = "foreign_path"

    var installed: Bool {
        self == .managedStub || self == .staleManagedStub
    }

    var repairable: Bool {
        switch self {
        case .missing, .managedStub, .staleManagedStub, .legacySymlink:
            return true
        case .foreignSymlink, .foreignPath:
            return false
        }
    }

    var needsRefresh: Bool {
        self == .staleManagedStub || self == .legacySymlink
    }

    static func current(at url: URL) -> SkillInstallState {
        let fileManager = FileManager.default

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let destinationURL: URL
            if destination.hasPrefix("/") {
                destinationURL = URL(fileURLWithPath: destination)
            } else {
                destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
            }

            if destinationURL.standardizedFileURL.path == MiniWhisperPaths.coreSkillCopy.standardizedFileURL.path {
                return .legacySymlink
            }
            return .foreignSymlink
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return .foreignPath
        }

        let markerURL = url.appendingPathComponent(CoreSkill.managedMarkerFileName)
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return .foreignPath
        }

        let skillURL = url.appendingPathComponent("SKILL.md")
        let skillText = try? String(contentsOf: skillURL, encoding: .utf8)
        return skillText == CoreSkill.discoveryStub ? .managedStub : .staleManagedStub
    }
}

enum SkillInstaller {
    static func install() throws {
        let fileManager = FileManager.default
        let installURL = MiniWhisperPaths.coreSkillClaudeInstall

        switch SkillInstallState.current(at: installURL) {
        case .foreignSymlink, .foreignPath:
            throw CLIError.runtime("Refusing to replace unmanaged skill path: \(installURL.path)")
        case .managedStub, .staleManagedStub, .legacySymlink:
            try fileManager.removeItem(at: installURL)
        case .missing:
            break
        }

        try fileManager.createDirectory(at: MiniWhisperPaths.claudeSkills, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installURL, withIntermediateDirectories: true)

        try CoreSkill.discoveryStub.write(
            to: installURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try CoreSkill.managedMarkerText.write(
            to: installURL.appendingPathComponent(CoreSkill.managedMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    static func uninstall() throws {
        let fileManager = FileManager.default
        let installURL = MiniWhisperPaths.coreSkillClaudeInstall

        switch SkillInstallState.current(at: installURL) {
        case .managedStub, .staleManagedStub, .legacySymlink:
            try fileManager.removeItem(at: installURL)
        case .missing:
            return
        case .foreignSymlink, .foreignPath:
            throw CLIError.runtime("Refusing to remove unmanaged skill path: \(installURL.path)")
        }
    }
}
