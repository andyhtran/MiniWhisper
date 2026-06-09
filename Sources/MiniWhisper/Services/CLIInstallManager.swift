import AppKit
import CryptoKit
import Foundation
import Observation

@Observable
@MainActor
final class CLIInstallManager {
    static let shared = CLIInstallManager()

    enum InstallError: LocalizedError {
        case bundledCLIMissing
        case bundledFrameworkMissing
        case conflictingItemExists(path: String)
        case io(Error)

        var errorDescription: String? {
            switch self {
            case .bundledCLIMissing:
                return "The miniwhispercli binary is missing from the app bundle."
            case .bundledFrameworkMissing:
                return "The Whisper framework required by miniwhispercli is missing from the app bundle."
            case .conflictingItemExists(let path):
                return "An existing file already exists at \(path). Remove it before installing MiniWhisper CLI."
            case .io(let error):
                return error.localizedDescription
            }
        }
    }

    private(set) var bundledCLIAvailable = false
    private(set) var isInstalled = false
    private(set) var hasConflict = false
    private(set) var needsUpdate = false
    private(set) var isBroken = false

    private let cliName = "miniwhispercli"

    private var bundledCLI: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(cliName)
    }

    private var bundledWhisperFramework: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("whisper.framework", isDirectory: true)
    }

    private var managedSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniWhisper", isDirectory: true)
    }

    private var managedBinDir: URL {
        managedSupportDir
            .appendingPathComponent("bin", isDirectory: true)
    }

    private var managedCLI: URL {
        managedBinDir.appendingPathComponent(cliName)
    }

    private var managedFrameworksDir: URL {
        managedSupportDir.appendingPathComponent("Frameworks", isDirectory: true)
    }

    private var managedWhisperFramework: URL {
        managedFrameworksDir.appendingPathComponent("whisper.framework", isDirectory: true)
    }

    private var userBinDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private var userSymlink: URL {
        userBinDir.appendingPathComponent(cliName)
    }

    private init() {
        refresh()
    }

    var displayInstallPath: String {
        "~/.local/bin/\(cliName)"
    }

    var managedInstallPath: String {
        managedCLI.path
    }

    func refresh() {
        bundledCLIAvailable = bundledPayloadExists()

        let symlinkExists = itemExistsOrSymlink(at: userSymlink)
        let ours = isOurSymlink()
        hasConflict = symlinkExists && !ours
        isBroken = ours
            && (!FileManager.default.fileExists(atPath: managedCLI.path)
                || !FileManager.default.fileExists(atPath: managedWhisperFramework.path))
        isInstalled = ours && !isBroken
        needsUpdate = isInstalled
            && bundledCLIAvailable
            && (bundledHash() != managedHash()
                || bundledFrameworkHash() != managedFrameworkHash())
    }

    func installOrUpdate() throws {
        guard let bundledCLI, bundledFileExists() else {
            throw InstallError.bundledCLIMissing
        }
        guard let bundledWhisperFramework, bundledFrameworkExists() else {
            throw InstallError.bundledFrameworkMissing
        }

        do {
            try FileManager.default.createDirectory(at: managedBinDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: managedFrameworksDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: userBinDir, withIntermediateDirectories: true)

            if itemExistsOrSymlink(at: userSymlink), !isOurSymlink() {
                throw InstallError.conflictingItemExists(path: userSymlink.path)
            }

            if FileManager.default.fileExists(atPath: managedCLI.path) {
                try FileManager.default.removeItem(at: managedCLI)
            }
            try FileManager.default.copyItem(at: bundledCLI, to: managedCLI)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: managedCLI.path
            )

            if FileManager.default.fileExists(atPath: managedWhisperFramework.path) {
                try FileManager.default.removeItem(at: managedWhisperFramework)
            }
            try FileManager.default.copyItem(at: bundledWhisperFramework, to: managedWhisperFramework)

            if isOurSymlink() {
                try FileManager.default.removeItem(at: userSymlink)
            }
            try FileManager.default.createSymbolicLink(at: userSymlink, withDestinationURL: managedCLI)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.io(error)
        }

        refresh()
    }

    func uninstall() throws {
        do {
            if isOurSymlink() {
                try FileManager.default.removeItem(at: userSymlink)
            }

            if FileManager.default.fileExists(atPath: managedCLI.path) {
                try FileManager.default.removeItem(at: managedCLI)
            }

            if FileManager.default.fileExists(atPath: managedWhisperFramework.path) {
                try FileManager.default.removeItem(at: managedWhisperFramework)
            }

            removeDirectoryIfEmpty(managedFrameworksDir)
            removeDirectoryIfEmpty(managedBinDir)
        } catch {
            throw InstallError.io(error)
        }

        refresh()
    }

    func revealInstallLocation() {
        if itemExistsOrSymlink(at: userSymlink) {
            NSWorkspace.shared.selectFile(userSymlink.path, inFileViewerRootedAtPath: userBinDir.path)
        } else if FileManager.default.fileExists(atPath: userBinDir.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: userBinDir.path)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: managedSupportDir.path)
        }
    }

    private func bundledPayloadExists() -> Bool {
        bundledFileExists() && bundledFrameworkExists()
    }

    private func bundledFileExists() -> Bool {
        guard let bundledCLI else { return false }
        return FileManager.default.fileExists(atPath: bundledCLI.path)
    }

    private func bundledFrameworkExists() -> Bool {
        guard let bundledWhisperFramework else { return false }
        return FileManager.default.fileExists(atPath: bundledWhisperFramework.path)
    }

    private func itemExistsOrSymlink(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func isOurSymlink() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: userSymlink.path),
              (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: userSymlink.path)
        else {
            return false
        }

        return URL(fileURLWithPath: destination).standardizedFileURL.path
            == managedCLI.standardizedFileURL.path
    }

    private func bundledHash() -> String? {
        guard let bundledCLI, FileManager.default.fileExists(atPath: bundledCLI.path) else {
            return nil
        }
        return try? Self.sha256(of: bundledCLI)
    }

    private func managedHash() -> String? {
        guard FileManager.default.fileExists(atPath: managedCLI.path) else {
            return nil
        }
        return try? Self.sha256(of: managedCLI)
    }

    private func bundledFrameworkHash() -> String? {
        guard let bundledWhisperFramework, FileManager.default.fileExists(atPath: bundledWhisperFramework.path) else {
            return nil
        }
        return try? Self.sha256Tree(of: bundledWhisperFramework)
    }

    private func managedFrameworkHash() -> String? {
        guard FileManager.default.fileExists(atPath: managedWhisperFramework.path) else {
            return nil
        }
        return try? Self.sha256Tree(of: managedWhisperFramework)
    }

    private func removeDirectoryIfEmpty(_ url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.isEmpty
        else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Tree(of root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { lhs, rhs in
                lhs.path < rhs.path
            }

        var hasher = SHA256()
        for file in files {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file))
            hasher.update(data: Data([0]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
