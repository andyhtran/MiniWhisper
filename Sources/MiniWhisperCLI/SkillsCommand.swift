import Foundation

struct RuntimeSkillInfo: Encodable {
    let name: String
    let description: String
}

enum RuntimeSkills {
    static let visible = [
        RuntimeSkillInfo(
            name: "core",
            description: "Local transcription routing, model choice, output artifacts, and diagnostics"
        )
    ]

    static var names: [String] {
        visible.map { $0.name }
    }

    static func markdown(named name: String) -> String? {
        switch name {
        case "core": return CoreSkill.text
        default: return nil
        }
    }
}

enum CoreSkill {
    static let directoryName = "miniwhisper"
    static let managedMarkerFileName = ".miniwhisper-managed-skill"
    static let managedMarkerText = "miniwhispercli managed discovery stub\n"

    static let discoveryStub =
        """
        ---
        name: miniwhisper
        description: MiniWhisper automation via the `miniwhispercli` CLI. Use when the user asks to work with local audio transcription, Parakeet, Whisper, speech-to-text, transcripts, subtitles, or timestamped local audio files. This stub points at the CLI's own runtime guides so instructions always match the installed version.
        ---

        # miniwhisper discovery stub

        Start here:
          miniwhispercli skills get core
          miniwhispercli skills list --json

        Version-matched guidance lives in the installed binary.
        """

    static let text =
        """
        ---
        name: miniwhisper-core
        description: Runtime guidance for MiniWhisper CLI local audio transcription with Parakeet and Whisper.
        ---

        # MiniWhisper Core

        Use MiniWhisper CLI when the user asks to transcribe a local audio file with MiniWhisper, Parakeet, or local Whisper.

        ## Core Workflow

        1. Confirm the audio file path exists before running transcription.
        2. Choose the model from the language and user request.
        3. Choose the output shape based on the requested artifact.
        4. Run `miniwhispercli transcribe <audio>` with the smallest flag set that satisfies the request.
        5. Use diagnostics/setup commands only if transcription fails or model readiness is uncertain.

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

struct SkillsListOutput: Encodable {
    let ok: Bool
    let skills: [RuntimeSkillInfo]
}

struct SkillsGetOutput: Encodable {
    let ok: Bool
    let name: String
    let markdown: String
}

enum SkillsCommand {
    static func run(arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            return list(arguments: [])
        }

        if subcommand == "-h" || subcommand == "--help" {
            printHelp()
            return 0
        }

        if subcommand.hasPrefix("-") {
            return list(arguments: arguments)
        }

        let rest = Array(arguments.dropFirst())

        switch subcommand {
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
        if arguments.contains("-h") || arguments.contains("--help") {
            printHelp()
            return 0
        }

        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown skills list option: \(unknown)")
            return 2
        }

        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: SkillsListOutput(ok: true, skills: RuntimeSkills.visible)))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        Console.out(renderSkillsList(RuntimeSkills.visible))
        return 0
    }

    private static func get(arguments: [String]) -> Int32 {
        var emitJSON = false
        var name: String?

        for argument in arguments {
            if argument == "--json" {
                emitJSON = true
            } else if argument.hasPrefix("-") {
                Console.error("Unknown skills get option: \(argument)")
                return 2
            } else if name == nil {
                name = argument
            } else {
                Console.error("Unexpected extra argument: \(argument)")
                Console.error("Usage: miniwhispercli skills get <name> [--json]")
                return 2
            }
        }

        guard let name else {
            Console.error("Missing skill name. Available: \(RuntimeSkills.names.joined(separator: ", "))")
            Console.error("Usage: miniwhispercli skills get <name>")
            Console.error("Examples:")
            Console.error("  miniwhispercli skills list")
            Console.error("  miniwhispercli skills get core")
            return 2
        }

        guard let markdown = RuntimeSkills.markdown(named: name) else {
            Console.error("Unknown skill: \(name). Available: \(RuntimeSkills.names.joined(separator: ", "))")
            Console.error("Try: miniwhispercli skills list")
            return 2
        }

        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: SkillsGetOutput(ok: true, name: name, markdown: markdown)))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        Console.write(markdown)
        if !markdown.hasSuffix("\n") {
            Console.out()
        }
        return 0
    }

    private static func renderSkillsList(_ skills: [RuntimeSkillInfo]) -> String {
        let nameWidth = max("NAME".count, skills.map { $0.name.count }.max() ?? 0)
        let header = "  \(pad("NAME", to: nameWidth))  DESCRIPTION"
        let separator = "  \(String(repeating: "-", count: nameWidth))  -----------"
        let rows = skills.map { skill in
            "  \(pad(skill.name, to: nameWidth))  \(skill.description)"
        }
        let next = skillsListNextCommands(skills).map { "  \($0)" }

        return (["Skills", "", header, separator] + rows + ["", "Next:"] + next)
            .joined(separator: "\n")
    }

    private static func skillsListNextCommands(_ skills: [RuntimeSkillInfo]) -> [String] {
        let available = Set(skills.map { $0.name })
        return ["core", "setup", "auth"]
            .filter { available.contains($0) }
            .map { "miniwhispercli skills get \($0)" }
    }

    private static func pad(_ value: String, to width: Int) -> String {
        let count = value.count
        guard count < width else { return value }
        return value + String(repeating: " ", count: width - count)
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              miniwhispercli skills
              miniwhispercli skills list [--json]
              miniwhispercli skills get <name> [--json]

            Examples:
              miniwhispercli skills list
              miniwhispercli skills list --json
              miniwhispercli skills get core
            """
        )
    }
}

struct SkillTarget: Encodable {
    let name: String
    let source: String
    let skillDir: String

    var skillPath: String {
        URL(fileURLWithPath: skillDir)
            .appendingPathComponent(CoreSkill.directoryName, isDirectory: true)
            .path
    }

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case skillDir = "skill_dir"
    }
}

struct SkillCommandOptions {
    var emitJSON = false
    var apply = false
    var dryRun = false
    var codex = false
    var targetName: String?
    var skillDir: String?

    func resolvedTarget() throws -> SkillTarget {
        if let skillDir, !skillDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = PathResolver.fileURL(for: skillDir)
            return SkillTarget(name: "custom", source: "flag", skillDir: url.path)
        }

        var target = targetName ?? "claude"
        if codex {
            if targetName == "claude" {
                throw CLIError.usage("--target claude and --codex contradict; choose one target.")
            }
            target = "codex"
        }

        switch target {
        case "claude":
            if let override = ProcessInfo.processInfo.environment["MINIWHISPER_CLAUDE_SKILL_DIR"],
               !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillTarget(name: "claude", source: "env:MINIWHISPER_CLAUDE_SKILL_DIR", skillDir: PathResolver.fileURL(for: override).path)
            }
            return SkillTarget(name: "claude", source: "default", skillDir: MiniWhisperPaths.claudeSkills.path)
        case "codex":
            if let override = ProcessInfo.processInfo.environment["MINIWHISPER_CODEX_SKILL_DIR"],
               !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SkillTarget(name: "codex", source: "env:MINIWHISPER_CODEX_SKILL_DIR", skillDir: PathResolver.fileURL(for: override).path)
            }
            return SkillTarget(name: "codex", source: "default", skillDir: MiniWhisperPaths.codexSkills.path)
        default:
            throw CLIError.usage("Unknown skill target: \(target). Expected claude or codex.")
        }
    }
}

struct SkillStatusOutput: Encodable {
    let ok: Bool
    let target: SkillTarget
    let strategy: String
    let skillPath: String
    let skillFile: String
    let markerPath: String
    let state: String
    let installed: Bool
    let managed: Bool
    let repairable: Bool
    let needsRefresh: Bool
    let runtimeGuidanceCommand: String
    let dryRun: Bool?
    let wouldWrite: Bool?
    let removed: Bool?
    let nextActions: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case target
        case strategy
        case skillPath = "skill_path"
        case skillFile = "skill_file"
        case markerPath = "marker_path"
        case state
        case installed
        case managed
        case repairable
        case needsRefresh = "needs_refresh"
        case runtimeGuidanceCommand = "runtime_guidance_command"
        case dryRun = "dry_run"
        case wouldWrite = "would_write"
        case removed
        case nextActions = "next_actions"
    }

    static func current(target: SkillTarget, dryRun: Bool? = nil, removed: Bool? = nil) -> SkillStatusOutput {
        let installURL = URL(fileURLWithPath: target.skillPath)
        let state = SkillInstallState.current(at: installURL)
        let installed = state.installed
        let repairable = state.repairable
        let needsRefresh = state.needsRefresh
        let commandSuffix = targetCommandSuffix(for: target)
        let nextActions: [String]

        if !repairable {
            nextActions = ["Move the existing skill path, then run miniwhispercli skill status\(commandSuffix)."]
        } else if !installed || needsRefresh {
            nextActions = ["miniwhispercli skill install\(commandSuffix) --apply"]
        } else {
            nextActions = ["miniwhispercli skills get core"]
        }

        return SkillStatusOutput(
            ok: true,
            target: target,
            strategy: "managed_discovery_stub",
            skillPath: installURL.path,
            skillFile: installURL.appendingPathComponent("SKILL.md").path,
            markerPath: installURL.appendingPathComponent(CoreSkill.managedMarkerFileName).path,
            state: state.rawValue,
            installed: installed,
            managed: state.managed,
            repairable: repairable,
            needsRefresh: needsRefresh,
            runtimeGuidanceCommand: "miniwhispercli skills get core",
            dryRun: dryRun,
            wouldWrite: dryRun == true ? repairable && (!installed || needsRefresh) : nil,
            removed: removed,
            nextActions: nextActions
        )
    }

    private static func targetCommandSuffix(for target: SkillTarget) -> String {
        switch target.name {
        case "codex":
            return " --codex"
        case "custom":
            return " --skill-dir \(shellQuote(target.skillDir))"
        default:
            return ""
        }
    }

    private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum SkillInstallState: String {
    case missing
    case managed
    case stale
    case foreignSymlink = "foreign_symlink"
    case foreignPath = "foreign_path"

    var installed: Bool {
        self == .managed || self == .stale
    }

    var managed: Bool {
        self == .managed || self == .stale
    }

    var repairable: Bool {
        self == .missing || self == .managed || self == .stale
    }

    var needsRefresh: Bool {
        self == .stale
    }

    static func current(at url: URL) -> SkillInstallState {
        let fileManager = FileManager.default

        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
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
        return skillText == CoreSkill.discoveryStub ? .managed : .stale
    }
}

enum SkillCommand {
    static func run(arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            return status(arguments: [])
        }

        if subcommand == "-h" || subcommand == "--help" {
            printHelp()
            return 0
        }

        if subcommand.hasPrefix("-") {
            return status(arguments: arguments)
        }

        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "status":
            return status(arguments: rest)
        case "install":
            return install(arguments: rest)
        case "show":
            return show(arguments: rest)
        case "uninstall":
            return uninstall(arguments: rest)
        default:
            Console.error("Unknown skill command: \(subcommand)")
            return 2
        }
    }

    private static func status(arguments: [String]) -> Int32 {
        do {
            let options = try parseOptions(arguments, allowJSON: true)
            let target = try options.resolvedTarget()
            let status = SkillStatusOutput.current(target: target)
            return emitStatus(status, title: "Skill status", emitJSON: options.emitJSON)
        } catch {
            return report(error)
        }
    }

    private static func install(arguments: [String]) -> Int32 {
        do {
            let options = try parseOptions(arguments, allowJSON: true, allowApply: true, allowDryRun: true)
            if options.apply && options.dryRun {
                throw CLIError.usage("--dry-run and --apply are mutually exclusive.")
            }

            let target = try options.resolvedTarget()
            if !options.apply {
                let status = SkillStatusOutput.current(target: target, dryRun: true)
                return emitStatus(status, title: "Skill install preview", emitJSON: options.emitJSON)
            }

            try SkillInstaller.install(target: target)
            let status = SkillStatusOutput.current(target: target, dryRun: false)
            return emitStatus(status, title: "Skill install", emitJSON: options.emitJSON)
        } catch {
            return report(error)
        }
    }

    private static func show(arguments: [String]) -> Int32 {
        do {
            let options = try parseOptions(arguments, allowJSON: true, allowTarget: false)
            if options.emitJSON {
                let output = SkillShowOutput(ok: true, content: CoreSkill.discoveryStub)
                Console.out(try JSONPrinter.string(from: output))
            } else {
                Console.write(CoreSkill.discoveryStub)
                if !CoreSkill.discoveryStub.hasSuffix("\n") {
                    Console.out()
                }
            }
            return 0
        } catch {
            return report(error)
        }
    }

    private static func uninstall(arguments: [String]) -> Int32 {
        do {
            let options = try parseOptions(arguments, allowJSON: true)
            let target = try options.resolvedTarget()
            let removed = try SkillInstaller.uninstall(target: target)
            let status = SkillStatusOutput.current(target: target, removed: removed)
            return emitStatus(status, title: "Skill uninstall", emitJSON: options.emitJSON)
        } catch {
            return report(error)
        }
    }

    private static func parseOptions(
        _ arguments: [String],
        allowJSON: Bool = false,
        allowApply: Bool = false,
        allowDryRun: Bool = false,
        allowTarget: Bool = true
    ) throws -> SkillCommandOptions {
        var options = SkillCommandOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json" where allowJSON:
                options.emitJSON = true
            case "--apply" where allowApply:
                options.apply = true
            case "--dry-run" where allowDryRun:
                options.dryRun = true
            case "--codex" where allowTarget:
                options.codex = true
            case "--target" where allowTarget:
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("Missing value for --target. Expected claude or codex.")
                }
                options.targetName = arguments[index]
            case "--skill-dir" where allowTarget:
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("Missing value for --skill-dir.")
                }
                options.skillDir = arguments[index]
            default:
                throw CLIError.usage("Unknown skill option: \(argument)")
            }
            index += 1
        }

        if let target = options.targetName,
           target != "claude" && target != "codex" {
            throw CLIError.usage("Unknown skill target: \(target). Expected claude or codex.")
        }

        return options
    }

    private static func emitStatus(_ status: SkillStatusOutput, title: String, emitJSON: Bool) -> Int32 {
        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: status))
                return 0
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        let actions = status.nextActions.map { "  \($0)" }.joined(separator: "\n")
        let modeLine = status.dryRun == true ? "\nMode: preview; pass --apply to write files" : ""
        Console.out(
            """
            \(title)

            Target: \(status.target.name) (\(status.target.source))
            Path: \(status.skillPath)
            State: \(status.state)
            Strategy: \(status.strategy)\(modeLine)

            Next:
            \(actions)
            """
        )
        return 0
    }

    private static func report(_ error: Error) -> Int32 {
        if case CLIError.usage(let message) = error {
            Console.error(message)
            Console.error("Run `miniwhispercli skill --help` for usage.")
            return 2
        }
        Console.error(error.localizedDescription)
        return 1
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              miniwhispercli skill
              miniwhispercli skill status [--json] [target options]
              miniwhispercli skill install [--dry-run|--apply] [target options]
              miniwhispercli skill show [--json]
              miniwhispercli skill uninstall [--json] [target options]

            Target options:
              --target <claude|codex>   Agent target (default: claude)
              --codex                   Shortcut for --target codex
              --skill-dir <dir>         Override the agent skill directory

            Examples:
              miniwhispercli skill install
              miniwhispercli skill install --apply
              miniwhispercli skill status --json
              miniwhispercli skill show
            """
        )
    }
}

struct SkillShowOutput: Encodable {
    let ok: Bool
    let content: String
}

enum SkillInstaller {
    static func install(target: SkillTarget) throws {
        let fileManager = FileManager.default
        let installURL = URL(fileURLWithPath: target.skillPath)

        switch SkillInstallState.current(at: installURL) {
        case .foreignSymlink, .foreignPath:
            throw CLIError.runtime("Refusing to replace unmanaged skill path: \(installURL.path)")
        case .managed:
            return
        case .stale:
            try fileManager.removeItem(at: installURL)
        case .missing:
            break
        }

        try fileManager.createDirectory(atPath: target.skillDir, withIntermediateDirectories: true)
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

    @discardableResult
    static func uninstall(target: SkillTarget) throws -> Bool {
        let fileManager = FileManager.default
        let installURL = URL(fileURLWithPath: target.skillPath)

        switch SkillInstallState.current(at: installURL) {
        case .managed, .stale:
            try fileManager.removeItem(at: installURL)
            return true
        case .missing:
            return false
        case .foreignSymlink, .foreignPath:
            throw CLIError.runtime("Refusing to remove unmanaged skill path: \(installURL.path)")
        }
    }
}
