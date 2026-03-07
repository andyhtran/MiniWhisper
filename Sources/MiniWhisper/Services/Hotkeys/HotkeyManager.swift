import Foundation
import Carbon.HIToolbox
import AppKit

@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    nonisolated func hotkeyDidToggleRecording()
    nonisolated func hotkeyDidCancelRecording()
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
