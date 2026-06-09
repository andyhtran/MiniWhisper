import Darwin
import Foundation

enum Console {
    static func out(_ message: String = "") {
        print(message)
    }

    static func write(_ message: String) {
        fputs(message, stdout)
    }

    static func error(_ message: String = "") {
        fputs(message + "\n", stderr)
    }
}

enum JSONPrinter {
    static func string<T: Encodable>(from value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIError.runtime("Failed to encode JSON as UTF-8.")
        }

        return string
    }

    static func write<T: Encodable>(_ value: T, to path: String) throws {
        let url = PathResolver.fileURL(for: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try string(from: value).data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
    }
}

enum TextFileWriter {
    static func write(_ value: String, to path: String) throws {
        let url = PathResolver.fileURL(for: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum CLIError: Error, LocalizedError {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message):
            return message
        }
    }
}
