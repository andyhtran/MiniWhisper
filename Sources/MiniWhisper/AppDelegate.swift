import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var hotkeyManager: HotkeyManager?
    private var hotkeyDelegate: HotkeyDelegateImpl?
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Disable App Nap for reliable background operation
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Audio recording and transcription"
        )

        let appState = AppState()
        self.appState = appState

        setupStatusItem()
        setupPopover()
        observeIconState()

        Task {
            await setupServices()
        }
    }

    // MARK: - Status Item & Popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.render(state: .idle, meterLevel: 0)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = VibrancyHostingController(
            rootView: MenuBarView().environment(appState)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Icon Observation

    /// Continuously observes recorder state and meter level to keep the
    /// status item icon in sync. Re-registers after every change.
    private func observeIconState() {
        withObservationTracking {
            _ = self.appState.recorder.state
            _ = self.appState.recorder.meterLevel
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeIconState()
            }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = MenuBarIconRenderer.render(
            state: appState.recorder.state,
            meterLevel: appState.recorder.meterLevel
        )
    }

    private func setupServices() async {
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

// MARK: - Vibrancy Hosting

/// Hosting view that opts into vibrancy so the popover content participates
/// in the system's glass/translucency effect rather than painting an opaque
/// backing.
private final class VibrancyHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { true }
}

/// View controller wrapper for VibrancyHostingView, since NSPopover requires
/// a contentViewController (not just a view).
private final class VibrancyHostingController<Content: View>: NSViewController {
    private let hostingView: VibrancyHostingView<Content>

    init(rootView: Content) {
        hostingView = VibrancyHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = hostingView
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
