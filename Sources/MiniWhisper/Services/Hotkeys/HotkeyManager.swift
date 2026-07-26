import Foundation
import Carbon.HIToolbox
import AppKit

@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    nonisolated func hotkeyDidToggleRecording()
    nonisolated func hotkeyDidCancelRecording()
    nonisolated func hotkeyDidToggleAutoCleanupRecording()
    nonisolated func hotkeyDidEditSelection()
}

@MainActor
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private let shortcutMonitor = CustomShortcutMonitor.shared

    /// Backs the cancel shortcut's enabled check, which is read from the
    /// modifier tap's thread as well as the main actor.
    nonisolated(unsafe) var _recordingActive = false
    let recordingActiveLock = NSLock()

    func start() {
        setupToggleRecording()
        setupCancelRecording()
        setupAutoCleanupRecording()
        setupEditSelection()
        shortcutMonitor.start()
    }

    func stop() {
        shortcutMonitor.stop()
    }

    func reloadShortcuts() {
        shortcutMonitor.reloadShortcuts()
    }

    // Recording state feeds the cancel shortcut's enabled check, and a
    // registered hot key swallows its chord unconditionally — so gating means
    // registering and unregistering, not filtering at fire time. Both edges
    // therefore have to re-derive the registrations.
    func recordingDidStart() {
        recordingActiveLock.lock()
        _recordingActive = true
        recordingActiveLock.unlock()
        shortcutMonitor.refresh()
    }

    func recordingDidEnd() {
        recordingActiveLock.lock()
        _recordingActive = false
        recordingActiveLock.unlock()
        shortcutMonitor.refresh()
    }

    private func setupToggleRecording() {
        shortcutMonitor.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.delegate?.hotkeyDidToggleRecording()
        }
    }

    private func setupCancelRecording() {
        let checker = RecordingActiveChecker(manager: self)
        shortcutMonitor.setEnabledCheck(for: .cancelRecording) {
            checker.isActive
        }
        shortcutMonitor.onKeyUp(for: .cancelRecording) { [weak self] in
            self?.delegate?.hotkeyDidCancelRecording()
        }
    }

    private func setupAutoCleanupRecording() {
        // Gate on the AI Editing setting so the shortcut passes through to the
        // frontmost app when auto-cleanup isn't enabled. Changing that setting
        // must re-derive registrations, or the hot key stays registered and
        // keeps swallowing the chord. Mirrors editSelection's pattern.
        shortcutMonitor.setEnabledCheck(for: .autoCleanupRecording) {
            EditModeSettings.behavior.autoCleanupEnabled
        }
        shortcutMonitor.onKeyDown(for: .autoCleanupRecording) { [weak self] in
            self?.delegate?.hotkeyDidToggleAutoCleanupRecording()
        }
    }

    private func setupEditSelection() {
        // Gate on the persisted setting so when edit mode is off, whatever the
        // user bound passes through to the frontmost app instead of being
        // consumed. Changing that setting must re-derive registrations so the
        // hot key is actually dropped.
        shortcutMonitor.setEnabledCheck(for: .editSelection) {
            EditModeSettings.behavior.selectionEnabled
        }
        // Fire on keyUp so the user's modifier (e.g. ⌥) has been released
        // before we synthesize ⌘C — otherwise the held modifier combines
        // with the synthetic Cmd and the target app sees ⌥⌘C instead.
        shortcutMonitor.onKeyUp(for: .editSelection) { [weak self] in
            self?.delegate?.hotkeyDidEditSelection()
        }
    }
}

/// Thread-safe Sendable helper for checking recording state from the event tap thread
private final class RecordingActiveChecker: @unchecked Sendable {
    private weak var manager: HotkeyManager?

    init(manager: HotkeyManager) {
        self.manager = manager
    }

    var isActive: Bool {
        guard let manager else { return false }
        manager.recordingActiveLock.lock()
        defer { manager.recordingActiveLock.unlock() }
        return manager._recordingActive
    }
}
