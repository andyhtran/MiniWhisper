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
    private var processingAnimationTimer: Timer?
    private var processingAnimationPhase: Double = 0
    let updaterController: UpdaterProviding = makeUpdaterController()

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
        scheduleLaunchRevealIfNeeded(notification)

        Task {
            await setupServices()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealMenuBarInterface()
        return true
    }

    // MARK: - Status Item & Popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "MiniWhisper.StatusItem"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.render(state: .idle, meterLevel: 0)
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.toolTip = "MiniWhisper"
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = VibrancyHostingController(
            rootView: MenuBarView()
                .environment(appState)
                .environment(\.updaterController, updaterController)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            _ = showPopover()
        }
    }

    private func scheduleLaunchRevealIfNeeded(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
            ?? true
        guard isDefaultLaunch else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.revealMenuBarInterface()
        }
    }

    private func revealMenuBarInterface() {
        let shouldShowHint = consumeMenuBarVisibilityHintAllowance()

        if showPopover() {
            appState.showMenuBarVisibilityHint = shouldShowHint
        } else if shouldShowHint {
            appState.showMenuBarVisibilityHint = false
            ToastWindowController.shared.showInfo(
                title: "Can't see MiniWhisper?",
                message: "Hold ⌘ and drag the waveform icon closer to the clock, or open Menu Bar Settings."
            )
        } else {
            appState.showMenuBarVisibilityHint = false
        }
    }

    private func consumeMenuBarVisibilityHintAllowance() -> Bool {
        let dismissedKey = "MenuBarVisibilityHintDismissed"
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return false }

        let countKey = "MenuBarVisibilityHintShownCount"
        let count = UserDefaults.standard.integer(forKey: countKey)
        guard count < 3 else { return false }

        UserDefaults.standard.set(count + 1, forKey: countKey)
        return true
    }

    private func showPopover() -> Bool {
        statusItem.isVisible = true

        guard let button = statusItem.button, button.window != nil else {
            return false
        }

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        guard popover.isShown else {
            return false
        }

        popover.contentViewController?.view.window?.makeKey()
        return true
    }

    // MARK: - Icon Observation

    /// Continuously observes recorder state and meter level to keep the
    /// status item icon in sync. Re-registers after every change.
    private func observeIconState() {
        withObservationTracking {
            _ = self.appState.recorder.state
            _ = self.appState.recorder.meterLevel
            _ = self.appState.isEditModeProcessing
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeIconState()
            }
        }
    }

    private func updateIcon() {
        let isWorking =
            appState.recorder.state == .processing || appState.isEditModeProcessing
        syncProcessingAnimation(active: isWorking)
        statusItem.button?.image = MenuBarIconRenderer.render(
            state: appState.recorder.state,
            meterLevel: appState.recorder.meterLevel,
            isEditModeProcessing: appState.isEditModeProcessing,
            processingPhase: processingAnimationPhase
        )
    }

    /// During transcription/edit calls no observed property changes, so the
    /// pulsing icon needs its own frame timer; observation alone would leave
    /// it frozen for the whole working window.
    private func syncProcessingAnimation(active: Bool) {
        if active, processingAnimationTimer == nil {
            // 10 fps, full pulse cycle every 1.2s.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.processingAnimationPhase =
                        (self.processingAnimationPhase + 1.0 / 12.0)
                        .truncatingRemainder(dividingBy: 1.0)
                    self.updateIcon()
                }
            }
            // `.common` keeps the pulse running while menus/popovers track.
            RunLoop.main.add(timer, forMode: .common)
            processingAnimationTimer = timer
        } else if !active, let timer = processingAnimationTimer {
            timer.invalidate()
            processingAnimationTimer = nil
            processingAnimationPhase = 0
        }
    }

    private func setupServices() async {
        ClaudeSkillManager.shared.syncBundleToDocumentsIfClean()

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

    nonisolated func hotkeyDidToggleAutoCleanupRecording() {
        Task { @MainActor in
            self.appState?.toggleAutoCleanupRecording()
        }
    }

    nonisolated func hotkeyDidEditSelection() {
        Task { @MainActor in
            self.appState?.editSelection()
        }
    }
}
