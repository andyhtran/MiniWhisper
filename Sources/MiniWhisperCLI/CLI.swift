import Foundation

enum CLI {
    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            Help.printBareRoot()
            return 0
        }

        if Help.isRootFullHelp(arguments) {
            Help.printFull()
            return 0
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "-h", "--help":
            Help.printRoot()
            return 0
        case "-V", "--version":
            Console.out(Version.current)
            return 0
        case "transcribe":
            return await TranscribeCommand.run(arguments: rest)
        case "models":
            return await ModelsCommand.run(arguments: rest)
        case "paths":
            return PathsCommand.run(arguments: rest)
        case "doctor":
            return DoctorCommand.run(arguments: rest)
        case "skills":
            return SkillsCommand.run(arguments: rest)
        case "skill":
            return SkillCommand.run(arguments: rest)
        case "version":
            Console.out(Version.current)
            return 0
        default:
            Console.error("Unknown command: \(command)")
            Console.error("Run `miniwhispercli --help` for usage.")
            return 2
        }
    }
}

enum Help {
    static func isRootFullHelp(_ arguments: [String]) -> Bool {
        guard arguments.count == 2 else { return false }
        return arguments.contains { $0 == "--help" || $0 == "-h" }
            && arguments.contains("--full")
    }

    static func printBareRoot() {
        Console.out(
            """
            MiniWhisper CLI
            Local audio transcription with Parakeet and Whisper.

            Usage:
              miniwhispercli <command> [options]

            Start here (for AI agents):
              miniwhispercli skills get core
              miniwhispercli skills list --json

            Version-matched guidance. Load core first; use the JSON list for available guides.

            Next:
              miniwhispercli transcribe <audio>
              miniwhispercli models status
              miniwhispercli skill install --apply

            More:
              miniwhispercli skills list
              miniwhispercli --help
            """
        )
    }

    static func printRoot() {
        Console.out(
            """
            MiniWhisper CLI

            Usage:
              miniwhispercli <command> [options]

            Start here (for AI agents):
              miniwhispercli skills get core
              miniwhispercli skills list --json

            Version-matched guidance. Load core first; use the JSON list for available guides.

            Common commands:
              transcribe <audio>       Transcribe audio with Parakeet or Whisper
              models status            Show local model readiness
              models install parakeet  Install the default Parakeet model
              models install whisper   Install the optional Whisper model
              paths                    Show local model, skill, and binary paths
              doctor                   Check local CLI readiness

            Agent integration:
              skills list              List bundled runtime guides
              skills get core          Print the agent-facing core guide
              skill status             Show agent skill install status
              skill install            Preview discovery-stub install
              skill install --apply    Install the discovery stub
              skill show               Print the bundled discovery stub
              skill uninstall          Remove the managed discovery stub

            Useful examples:
              miniwhispercli transcribe audio.wav
              miniwhispercli transcribe audio.wav --model whisper
              miniwhispercli transcribe audio.wav --format json -o out.json
              miniwhispercli transcribe audio.wav --format srt -o out.srt
              miniwhispercli transcribe audio.wav --from 01:20 --duration 50
              miniwhispercli transcribe audio.wav --json
              miniwhispercli transcribe audio.wav --source system
              miniwhispercli models status
              miniwhispercli skill install --apply

            More help:
              miniwhispercli <command> --help
              miniwhispercli --help --full
              miniwhispercli skills list
              miniwhispercli skills get core
            """
        )
    }

    static func printFull() {
        Console.out(
            """
            Usage: miniwhispercli <command> [flags]

            MiniWhisper CLI local audio transcription.

            Flags:
              -h, --help                              Show help
              -V, --version                           Show version
                  --full                              With --help, show this full command reference

            Commands:
              transcribe <audio>                      Transcribe audio with Parakeet or Whisper
              models                                  Show local model readiness
              models status [--json]                  Show local model readiness
              models install <parakeet|whisper>       Install or verify a model
              paths [--json]                          Show model, skill, and binary paths
              doctor [--json]                         Check local CLI readiness
              skills                                  List bundled runtime guides
              skills list [--json]                    List bundled runtime guides
              skills get <name> [--json]              Print bundled runtime guidance
              skill                                   Show discovery-stub install status
              skill status [--json]                   Show discovery-stub install status
              skill install [--dry-run|--apply]       Preview or install the managed discovery stub
              skill show [--json]                     Print the bundled discovery stub
              skill uninstall [--json]                Remove the managed discovery stub
              version                                 Show version information

            Target options for skill commands:
                  --target <claude|codex>             Agent target (default: claude)
                  --codex                             Shortcut for --target codex
                  --skill-dir <dir>                   Override the agent skill directory

            Transcribe options:
                  --model <parakeet|whisper>          Transcription model (default: parakeet)
                  --source <microphone|system>        Parakeet audio-source normalization
                  --language <auto|code>              Whisper language (default: auto)
                  --from <time>                       Start offset; seconds, MM:SS, or HH:MM:SS
                  --to <time>                         End offset; seconds, MM:SS, or HH:MM:SS
                  --offset <time>                     Start offset as an alternative to --from
                  --duration <time>                   Clip duration as an alternative to --to
                  --streaming                         Force FluidAudio streaming transcription
                  --timestamps <none|segment|word>    Include clean timestamps in JSON
                  --word-timestamps                   Legacy stderr word timestamp dump
                  --metadata                          Print transcription metadata to stderr
                  --format <text|json|srt|vtt>        Primary output format (default: text)
              -o, --output <file>                     Write primary output to a file
                  --json                              Alias for --format json
                  --output-json <file>                Also write JSON result to a file
                  --output-srt <file>                 Also write SRT subtitles to a file
                  --output-vtt <file>                 Also write WebVTT subtitles to a file
                  --quiet                             Suppress progress messages on stderr

            More help:
              miniwhispercli <command> --help
              miniwhispercli skills get core

            Claude skills: \(MiniWhisperPaths.claudeSkills.path)
            """
        )
    }

    static func printTranscribe() {
        Console.out(
            """
            MiniWhisper CLI

            Usage:
              miniwhispercli transcribe <audio> [options]

            Options:
              --model <parakeet|whisper>
                                        Transcription model (default: parakeet)
              --source <microphone|system>
                                        Parakeet audio-source normalization (default: microphone)
              --language <auto|code>     Whisper language (default: auto)
              --from <time>              Start offset; accepts seconds, MM:SS, or HH:MM:SS
              --to <time>                End offset; accepts seconds, MM:SS, or HH:MM:SS
              --offset <time>            Start offset as an alternative to --from
              --duration <time>          Clip duration as an alternative to --to
              --streaming               Force FluidAudio streaming transcription
              --timestamps <none|segment|word>
                                        Include clean timestamps in JSON (default: none)
              --word-timestamps         Legacy: include word timestamps and print them to stderr
              --metadata                Print transcription metadata to stderr
              --format <text|json|srt|vtt>
                                        Primary output format (default: text)
              -o, --output <file>       Write primary output to a file
              --json                    Alias for --format json
              --output-json <file>      Also write JSON result to a file
              --output-srt <file>       Also write SRT subtitles to a file
              --output-vtt <file>       Also write WebVTT subtitles to a file
              --quiet                   Suppress progress messages on stderr
              -h, --help                Show this help

            Useful examples:
              miniwhispercli transcribe audio.wav
              miniwhispercli transcribe audio.wav --model whisper
              miniwhispercli transcribe audio.wav --model whisper --language ja --json
              miniwhispercli transcribe audio.wav --format json -o out.json --quiet
              miniwhispercli transcribe audio.wav --format srt -o out.srt
              miniwhispercli transcribe audio.wav --from 01:20 --duration 50
              miniwhispercli transcribe audio.wav --timestamps word --json
            """
        )
    }
}

enum Version {
    static var current: String {
        if let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return shortVersion
        }
        return "dev"
    }
}
