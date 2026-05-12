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

    /// Thread-safe flag for cancel shortcut's enabled check (accessed from event tap thread)
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

    func recordingDidStart() {
        recordingActiveLock.lock()
        _recordingActive = true
        recordingActiveLock.unlock()
    }

    func recordingDidEnd() {
        recordingActiveLock.lock()
        _recordingActive = false
        recordingActiveLock.unlock()
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
        // Gate at event-tap time on the AI Editing setting so the
        // shortcut passes through to the frontmost app when auto-cleanup
        // isn't enabled. Mirrors editSelection's pattern.
        shortcutMonitor.setEnabledCheck(for: .autoCleanupRecording) {
            EditModeSettings.behavior.autoCleanupEnabled
        }
        shortcutMonitor.onKeyDown(for: .autoCleanupRecording) { [weak self] in
            self?.delegate?.hotkeyDidToggleAutoCleanupRecording()
        }
    }

    private func setupEditSelection() {
        // Gate at event-tap time on the persisted setting so when edit
        // mode is off, ⌥E (or whatever the user bound) passes through to
        // the frontmost app instead of being consumed. UserDefaults is
        // thread-safe — no callback wiring needed.
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
