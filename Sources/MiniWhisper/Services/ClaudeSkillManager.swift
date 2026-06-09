import AppKit
import CryptoKit
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ClaudeSkillManager")

/// Ships the `mw-replace` skill from the app bundle into the user's Documents
/// folder and, when toggled on, copies it into Claude Code's skill directory at
/// `~/.claude/skills/mw-replace`.
///
/// Truth model is hash-based, not version-numbered:
///   - The app bundle carries the canonical `SKILL.md`.
///   - `~/Documents/MiniWhisper/skills/mw-replace/SKILL.md` is the editable copy.
///   - `~/.claude/skills/mw-replace/SKILL.md` is a real installed copy when enabled.
///   - A `.mw-sha` sibling marker holds the sha256 of whatever we last wrote.
/// Comparing the bundled hash, the active-file hash, and the marker tells us
/// whether the user has edited the file *and* whether a newer version is
/// available — orthogonally.
@Observable
@MainActor
final class ClaudeSkillManager {
    static let shared = ClaudeSkillManager()

    enum SyncStatus: Sendable, Equatable {
        case upToDate
        case updateAvailable
        case modified
        case modifiedAndUpdateAvailable
    }

    enum SkillError: LocalizedError {
        case claudeCodeNotInstalled
        case conflictingItemExists(path: String)
        case bundleResourceMissing
        case io(Error)

        var errorDescription: String? {
            switch self {
            case .claudeCodeNotInstalled:
                return "Claude Code is not installed (no ~/.claude directory found)."
            case .conflictingItemExists(let path):
                return "An existing file or skill already exists at \(path). Remove it to enable this skill."
            case .bundleResourceMissing:
                return "The skill resource is missing from the app bundle."
            case .io(let err):
                return err.localizedDescription
            }
        }
    }

    private(set) var claudeCodeInstalled: Bool = false
    private(set) var isEnabled: Bool = false
    private(set) var hasConflict: Bool = false
    private(set) var syncStatus: SyncStatus = .upToDate

    private let skillName = "mw-replace"
    private let skillFileName = "SKILL.md"
    private let markerFileName = ".mw-sha"

    // Bundle resources are immutable for the life of the process, so we hash
    // the shipped SKILL.md once at init and reuse it on every refresh. Saves
    // two file reads + a SHA256 per settings-popover open / toggle.
    private let bundledSkillFile: URL?
    private let bundledHash: String?

    // MARK: - Paths

    private var documentsSkillDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniWhisper/skills/\(skillName)")
    }

    private var documentsSkillFile: URL {
        documentsSkillDir.appendingPathComponent(skillFileName)
    }

    private var documentsShaMarker: URL {
        documentsSkillDir.appendingPathComponent(markerFileName)
    }

    private var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private var claudeSkillsDir: URL {
        claudeDir.appendingPathComponent("skills")
    }

    private var claudeInstallDir: URL {
        claudeSkillsDir.appendingPathComponent(skillName)
    }

    private var claudeSkillFile: URL {
        claudeInstallDir.appendingPathComponent(skillFileName)
    }

    private var claudeShaMarker: URL {
        claudeInstallDir.appendingPathComponent(markerFileName)
    }

    private init() {
        let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("skills/\(skillName)/\(skillFileName)")
        if let url = resourceURL, FileManager.default.fileExists(atPath: url.path) {
            bundledSkillFile = url
            bundledHash = try? Self.sha256(of: url)
        } else {
            bundledSkillFile = nil
            bundledHash = nil
        }
        refresh()
    }

    // MARK: - Launch-time sync

    /// Auto-copies bundle → Documents iff the user hasn't edited (or the
    /// Documents copy doesn't exist yet). Never clobbers user edits — when a
    /// newer bundle version ships over edited Documents content, the UI
    /// surfaces "Update available" and the user decides.
    func syncBundleToDocumentsIfClean() {
        guard let bundledURL = bundledSkillFile, let bundledHash else {
            log.info("No bundled skill found; skipping sync.")
            refresh()
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: documentsSkillFile.path) {
                try writeBundledCopy(from: bundledURL, hash: bundledHash)
                log.info("Seeded skill to Documents.")
                refresh()
                return
            }

            let currentHash = try Self.sha256(of: documentsSkillFile)
            let lastSynced = readMarker(at: documentsShaMarker)

            if currentHash == lastSynced && bundledHash != lastSynced {
                try writeBundledCopy(from: bundledURL, hash: bundledHash)
                log.info("Auto-updated skill from bundle (no user edits).")
            }
        } catch {
            log.error("syncBundleToDocumentsIfClean failed: \(error.localizedDescription)")
        }

        do {
            try syncEnabledClaudeInstallIfClean()
        } catch {
            log.error("syncEnabledClaudeInstallIfClean failed: \(error.localizedDescription)")
        }

        refresh()
    }

    // MARK: - State

    func refresh() {
        claudeCodeInstalled = FileManager.default.fileExists(atPath: claudeDir.path)
        let toggle = computeToggleState()
        isEnabled = toggle.enabled
        hasConflict = toggle.conflict
        syncStatus = computeSyncStatus()
    }

    private func computeToggleState() -> (enabled: Bool, conflict: Bool) {
        guard itemExists(at: claudeInstallDir)
        else {
            return (false, false)
        }

        return isManagedClaudeInstall() || isLegacySymlinkInstall()
            ? (true, false)
            : (false, true)
    }

    private func isManagedClaudeInstall() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: claudeInstallDir.path),
            (attrs[.type] as? FileAttributeType) == .typeDirectory
        else {
            return false
        }

        return FileManager.default.fileExists(atPath: claudeSkillFile.path)
            && FileManager.default.fileExists(atPath: claudeShaMarker.path)
    }

    private func isLegacySymlinkInstall() -> Bool {
        let path = claudeInstallDir.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else {
            return false
        }
        return target == documentsSkillDir.path
    }

    private func computeSyncStatus() -> SyncStatus {
        let syncTarget = activeSyncTarget()
        guard let bundledHash,
            FileManager.default.fileExists(atPath: syncTarget.skillFile.path)
        else {
            return .upToDate
        }

        do {
            let currentHash = try Self.sha256(of: syncTarget.skillFile)
            let lastSynced = readMarker(at: syncTarget.markerFile)

            let modified = (currentHash != lastSynced)
            let updateAvailable = (bundledHash != lastSynced)

            switch (modified, updateAvailable) {
            case (false, false): return .upToDate
            case (false, true): return .updateAvailable
            case (true, false): return .modified
            case (true, true): return .modifiedAndUpdateAvailable
            }
        } catch {
            log.error("computeSyncStatus failed: \(error.localizedDescription)")
            return .upToDate
        }
    }

    // MARK: - Toggle actions

    func enable() throws {
        guard claudeCodeInstalled else { throw SkillError.claudeCodeNotInstalled }

        do {
            try FileManager.default.createDirectory(
                at: claudeSkillsDir, withIntermediateDirectories: true)
            try ensureDocumentsCopyExists()
        } catch let error as SkillError {
            throw error
        } catch {
            throw SkillError.io(error)
        }

        if isManagedClaudeInstall() {
            refresh()
            return
        }
        if itemExists(at: claudeInstallDir), !isLegacySymlinkInstall() {
            throw SkillError.conflictingItemExists(path: claudeInstallDir.path)
        }

        do {
            try installClaudeCopyFromDocuments()
        } catch let error as SkillError {
            throw error
        } catch {
            throw SkillError.io(error)
        }
        refresh()
    }

    func disable() throws {
        guard isManagedClaudeInstall() || isLegacySymlinkInstall() else {
            refresh()
            return
        }
        do {
            if isManagedClaudeInstall() {
                try preserveInstalledEditsIfNeeded()
            }
            try FileManager.default.removeItem(at: claudeInstallDir)
        } catch {
            throw SkillError.io(error)
        }
        refresh()
    }

    // MARK: - Sync actions

    /// Overwrites the Documents copy with the bundled version. Used for both
    /// "apply available update" and "reset to default" — same operation.
    func applyBundledVersion() throws {
        guard let bundledURL = bundledSkillFile, let bundledHash else {
            throw SkillError.bundleResourceMissing
        }
        do {
            try writeBundledCopy(from: bundledURL, hash: bundledHash)
            if isManagedClaudeInstall() {
                try writeSkillFile(from: bundledURL, hash: bundledHash, to: claudeInstallDir)
            }
        } catch {
            throw SkillError.io(error)
        }
        refresh()
    }

    // MARK: - Navigation

    func revealConflictInFinder() {
        NSWorkspace.shared.selectFile(
            claudeInstallDir.path,
            inFileViewerRootedAtPath: claudeSkillsDir.path)
    }

    // MARK: - Helpers

    private func activeSyncTarget() -> (skillFile: URL, markerFile: URL) {
        if isManagedClaudeInstall() {
            return (claudeSkillFile, claudeShaMarker)
        }
        return (documentsSkillFile, documentsShaMarker)
    }

    private func syncEnabledClaudeInstallIfClean() throws {
        if isLegacySymlinkInstall() {
            try installClaudeCopyFromDocuments()
            return
        }

        guard isManagedClaudeInstall(),
              let bundledURL = bundledSkillFile,
              let bundledHash
        else {
            return
        }

        let currentHash = try Self.sha256(of: claudeSkillFile)
        let lastSynced = readMarker(at: claudeShaMarker)
        guard currentHash == lastSynced, bundledHash != lastSynced else { return }

        try writeSkillFile(from: bundledURL, hash: bundledHash, to: claudeInstallDir)
    }

    private func ensureDocumentsCopyExists() throws {
        guard !FileManager.default.fileExists(atPath: documentsSkillFile.path) else { return }
        guard let bundledURL = bundledSkillFile, let bundledHash else {
            throw SkillError.bundleResourceMissing
        }

        try writeBundledCopy(from: bundledURL, hash: bundledHash)
    }

    private func installClaudeCopyFromDocuments() throws {
        if itemExists(at: claudeInstallDir) {
            if isLegacySymlinkInstall() || isManagedClaudeInstall() {
                try FileManager.default.removeItem(at: claudeInstallDir)
            } else {
                throw SkillError.conflictingItemExists(path: claudeInstallDir.path)
            }
        }

        try FileManager.default.createDirectory(
            at: claudeInstallDir, withIntermediateDirectories: true)

        let data = try Data(contentsOf: documentsSkillFile)
        try data.write(to: claudeSkillFile, options: .atomic)

        let marker = readMarker(at: documentsShaMarker)
        if marker.isEmpty {
            let hash = try Self.sha256(of: documentsSkillFile)
            try hash.write(to: claudeShaMarker, atomically: true, encoding: .utf8)
        } else {
            try marker.write(to: claudeShaMarker, atomically: true, encoding: .utf8)
        }
    }

    private func preserveInstalledEditsIfNeeded() throws {
        let currentHash = try Self.sha256(of: claudeSkillFile)
        let lastSynced = readMarker(at: claudeShaMarker)
        guard !lastSynced.isEmpty, currentHash != lastSynced else { return }

        try FileManager.default.createDirectory(
            at: documentsSkillDir, withIntermediateDirectories: true)

        let data = try Data(contentsOf: claudeSkillFile)
        try data.write(to: documentsSkillFile, options: .atomic)
        // Keep the previous marker so the preserved Documents copy still
        // classifies as user-modified after disabling the Claude install.
        try lastSynced.write(to: documentsShaMarker, atomically: true, encoding: .utf8)
    }

    private func writeBundledCopy(from source: URL, hash: String) throws {
        try writeSkillFile(from: source, hash: hash, to: documentsSkillDir)
    }

    private func writeSkillFile(from source: URL, hash: String, to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let data = try Data(contentsOf: source)
        try data.write(to: directory.appendingPathComponent(skillFileName), options: .atomic)
        try hash.write(
            to: directory.appendingPathComponent(markerFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func readMarker(at url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func itemExists(at url: URL) -> Bool {
        // `fileExists` is false for dangling symlinks; attributes still let us
        // treat that path as occupied instead of overwriting it.
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
