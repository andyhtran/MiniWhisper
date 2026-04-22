import AppKit
import CryptoKit
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "ClaudeSkillManager")

/// Ships the `mw-replace` skill from the app bundle into the user's Documents
/// folder and, when toggled on, exposes it to Claude Code via a symlink at
/// `~/.claude/skills/mw-replace`.
///
/// Truth model is hash-based, not version-numbered:
///   - The app bundle carries the canonical `SKILL.md`.
///   - `~/Documents/MiniWhisper/skills/mw-replace/SKILL.md` is the live copy.
///   - A `.mw-sha` sibling marker holds the sha256 of whatever we last wrote.
/// Comparing the bundled hash, the live-file hash, and the marker tells us
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

    private var claudeSymlink: URL {
        claudeSkillsDir.appendingPathComponent(skillName)
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
            let lastSynced = readMarker()

            if currentHash == lastSynced && bundledHash != lastSynced {
                try writeBundledCopy(from: bundledURL, hash: bundledHash)
                log.info("Auto-updated skill from bundle (no user edits).")
            }
        } catch {
            log.error("syncBundleToDocumentsIfClean failed: \(error.localizedDescription)")
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
        // Nothing at the symlink path → no symlink, no conflict.
        guard FileManager.default.fileExists(atPath: claudeSymlink.path)
            || (try? FileManager.default.attributesOfItem(atPath: claudeSymlink.path)) != nil
        else {
            return (false, false)
        }
        return isOurSymlink() ? (true, false) : (false, true)
    }

    /// True only if `~/.claude/skills/mw-replace` is a symlink pointing at our
    /// Documents skill dir. A real file/dir, or a symlink pointing elsewhere,
    /// counts as a conflict (not ours, don't touch).
    private func isOurSymlink() -> Bool {
        let path = claudeSymlink.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else {
            return false
        }
        return target == documentsSkillDir.path
    }

    private func computeSyncStatus() -> SyncStatus {
        guard let bundledHash,
            FileManager.default.fileExists(atPath: documentsSkillFile.path)
        else {
            return .upToDate
        }

        do {
            let currentHash = try Self.sha256(of: documentsSkillFile)
            let lastSynced = readMarker()

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
        } catch {
            throw SkillError.io(error)
        }

        if isOurSymlink() {
            refresh()
            return  // already ours — idempotent
        }
        if (try? FileManager.default.attributesOfItem(atPath: claudeSymlink.path)) != nil {
            throw SkillError.conflictingItemExists(path: claudeSymlink.path)
        }

        do {
            try FileManager.default.createSymbolicLink(
                at: claudeSymlink, withDestinationURL: documentsSkillDir)
        } catch {
            throw SkillError.io(error)
        }
        refresh()
    }

    /// Safety-checked: only removes the symlink if it's ours. A non-symlink or
    /// a symlink pointing elsewhere is left alone (shouldn't have been toggled
    /// on in the first place).
    func disable() throws {
        guard isOurSymlink() else {
            refresh()
            return
        }
        do {
            try FileManager.default.removeItem(at: claudeSymlink)
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
        } catch {
            throw SkillError.io(error)
        }
        refresh()
    }

    // MARK: - Navigation

    /// Opens `~/.claude/skills/` with `mw-replace` selected so the user can
    /// inspect or delete whatever's blocking the symlink.
    func revealConflictInFinder() {
        NSWorkspace.shared.selectFile(
            claudeSymlink.path,
            inFileViewerRootedAtPath: claudeSkillsDir.path)
    }

    // MARK: - Helpers

    private func writeBundledCopy(from source: URL, hash: String) throws {
        try FileManager.default.createDirectory(
            at: documentsSkillDir, withIntermediateDirectories: true)

        let data = try Data(contentsOf: source)
        try data.write(to: documentsSkillFile, options: .atomic)
        try hash.write(to: documentsShaMarker, atomically: true, encoding: .utf8)
    }

    private func readMarker() -> String {
        guard let contents = try? String(contentsOf: documentsShaMarker, encoding: .utf8) else {
            return ""
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
