import AppKit
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "AppDelegate")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyManager: HotkeyManager?
    private var hotkeyDelegate: HotkeyDelegateImpl?
    private var appNapActivity: NSObjectProtocol?

    @MainActor var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Disable App Nap for reliable background operation
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Audio recording and transcription"
        )

        Task { @MainActor in
            // SwiftUI sets appDelegate.appState in MiniWhisperApp.init(), which runs
            // after NSApplicationDelegate adaptor creation but the timing is not
            // guaranteed relative to applicationDidFinishLaunching. 100ms is enough.
            try? await Task.sleep(for: .milliseconds(100))
            await setupServices()
        }
    }

    @MainActor
    private func setupServices() async {
        guard let appState else {
            log.error("AppDelegate.setupServices - appState not set")
            return
        }

        try? await appState.recordingStore.loadAll()
        appState.recordingStore.performRetention()

        let analyticsExisted = appState.analyticsStore.load()
        if !analyticsExisted {
            appState.analyticsStore.seedFromRecordings(appState.recordingStore.recordings)
        }

        let permissions = appState.permissions
        permissions.refresh()

        if !permissions.microphoneGranted {
            await permissions.requestMicrophone()
        }

        appState.preloadModel()

        let delegate = HotkeyDelegateImpl(appState: appState)
        let manager = HotkeyManager()
        manager.delegate = delegate
        hotkeyDelegate = delegate
        hotkeyManager = manager

        // Wire up recording state changes so HotkeyManager knows when cancel is valid
        appState.onRecordingStarted = { [weak manager] in
            manager?.recordingDidStart()
        }
        appState.onRecordingEnded = { [weak manager] in
            manager?.recordingDidEnd()
        }

        // When permissions are all granted, (re)start the event tap
        permissions.onAllGranted = { [weak manager] in
            log.info("All permissions granted — restarting hotkey manager")
            manager?.stop()
            manager?.start()
        }

        if permissions.accessibilityGranted {
            log.info("Starting hotkey manager (accessibility already granted)")
            manager.start()
        } else {
            permissions.openAccessibilitySettings()
            permissions.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}

@MainActor
final class HotkeyDelegateImpl: HotkeyManagerDelegate {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    nonisolated func hotkeyDidToggleRecording() {
        Task { @MainActor in
            self.appState?.toggleRecording()
        }
    }

    nonisolated func hotkeyDidCancelRecording() {
        Task { @MainActor in
            self.appState?.cancelRecording()
        }
    }
}
