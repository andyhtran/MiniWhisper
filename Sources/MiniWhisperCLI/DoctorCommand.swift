import Foundation

struct DoctorOutput: Encodable {
    let ok: Bool
    let checks: [DoctorCheck]
}

struct DoctorCheck: Encodable {
    let name: String
    let status: String
    let detail: String
}

enum DoctorCommand {
    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            printHelp()
            return 0
        }

        let emitJSON = arguments.contains("--json")
        let unknown = arguments.first { $0 != "--json" }
        if let unknown {
            Console.error("Unknown doctor option: \(unknown)")
            return 2
        }

        let checks = makeChecks()
        let output = DoctorOutput(
            ok: checks.allSatisfy { $0.status != "error" },
            checks: checks
        )

        if emitJSON {
            do {
                Console.out(try JSONPrinter.string(from: output))
                return output.ok ? 0 : 1
            } catch {
                Console.error(error.localizedDescription)
                return 1
            }
        }

        Console.out("MiniWhisper CLI doctor")
        Console.out("")
        for check in checks {
            Console.out("[\(check.status)] \(check.name): \(check.detail)")
        }

        return output.ok ? 0 : 1
    }

    private static func makeChecks() -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        #if arch(arm64)
        checks.append(DoctorCheck(name: "Apple Silicon", status: "ok", detail: "arm64"))
        #else
        checks.append(DoctorCheck(name: "Apple Silicon", status: "error", detail: "Parakeet CoreML models require Apple Silicon."))
        #endif

        let parakeetInstalled = ParakeetModel.isInstalled
        checks.append(
            DoctorCheck(
                name: "Parakeet models",
                status: parakeetInstalled ? "ok" : "warning",
                detail: parakeetInstalled
                    ? ParakeetModel.directory.path
                    : "Missing. `miniwhispercli models install parakeet` or first transcription will download them."
            )
        )

        let whisperInstalled = FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperModel.path)
        checks.append(
            DoctorCheck(
                name: "Whisper model",
                status: whisperInstalled ? "ok" : "warning",
                detail: whisperInstalled
                    ? MiniWhisperPaths.whisperModel.path
                    : "Missing. `miniwhispercli models install whisper` or first Whisper transcription will download it."
            )
        )

        let whisperVADInstalled = FileManager.default.fileExists(atPath: MiniWhisperPaths.whisperVADModel.path)
        checks.append(
            DoctorCheck(
                name: "Whisper VAD model",
                status: whisperVADInstalled ? "ok" : "warning",
                detail: whisperVADInstalled
                    ? MiniWhisperPaths.whisperVADModel.path
                    : "Missing. `miniwhispercli models install whisper` or first Whisper transcription will download it."
            )
        )

        let claudeSkillDirExists = FileManager.default.fileExists(atPath: MiniWhisperPaths.claudeSkills.path)
        checks.append(
            DoctorCheck(
                name: "Claude skill directory",
                status: claudeSkillDirExists ? "ok" : "warning",
                detail: claudeSkillDirExists
                    ? MiniWhisperPaths.claudeSkills.path
                    : "Missing. `miniwhispercli skill install --apply` will create it."
            )
        )

        return checks
    }

    private static func printHelp() {
        Console.out(
            """
            Usage:
              miniwhispercli doctor [--json]
            """
        )
    }
}
