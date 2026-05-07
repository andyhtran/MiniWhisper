import Foundation

/// Spawns the user's installed `claude` / `codex` CLI to make it refresh
/// its own OAuth token. We never refresh ourselves — that would
/// invalidate the CLI's stored refresh token (Anthropic rotates them on
/// every use). The CLI does the refresh as a side effect of any API
/// call, then writes the new tokens back to its own storage; we re-read.
enum OAuthRefreshTrigger {
    enum Error: LocalizedError {
        case binaryNotFound(String)
        case nonZeroExit(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let name):
                return "\(name) not found in PATH. Install it and run it once to log in."
            case .nonZeroExit(let name, let code, let stderr):
                let suffix = stderr.isEmpty ? "" : ": \(stderr)"
                return "\(name) refresh trigger exited \(code)\(suffix)"
            }
        }
    }

    private static let timeoutSeconds: Double = 60

    static func anthropic() async throws {
        let bin = try resolveBinary("claude")
        try await run(executable: bin, args: ["-p", "hi", "--model", "haiku"], name: "claude")
    }

    static func codex() async throws {
        let bin = try resolveBinary("codex")
        try await run(executable: bin, args: ["exec", "hi"], name: "codex")
    }

    // MARK: - Internals

    private static func run(executable: URL, args: [String], name: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice

            try process.run()

            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }
            process.waitUntilExit()
            watchdog.cancel()

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = (String(data: stderrData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Error.nonZeroExit(name, process.terminationStatus, stderrText.prefixCapped())
            }
        }.value
    }

    private static func resolveBinary(_ name: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw Error.binaryNotFound(name)
        }
        guard process.terminationStatus == 0 else {
            throw Error.binaryNotFound(name)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else {
            throw Error.binaryNotFound(name)
        }
        return URL(fileURLWithPath: path)
    }
}

private extension String {
    func prefixCapped(_ max: Int = 300) -> String {
        if count <= max { return self }
        return String(prefix(max)) + "…"
    }
}
