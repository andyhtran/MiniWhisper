import Darwin
import Foundation

@main
struct MiniWhisperCLI {
    static func main() async {
        let status = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(status)
    }
}

