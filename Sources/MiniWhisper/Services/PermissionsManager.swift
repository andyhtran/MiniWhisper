import Foundation
import AVFoundation
import AppKit
import Observation

@Observable
@MainActor
final class PermissionsManager: Sendable {
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false

    var onAllGranted: (() -> Void)?

    private var pollTimer: Timer?
    private var wasAllGranted = false

    init() {
        refresh()
        wasAllGranted = allGranted
    }

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Keyboard event taps of both flavors (.defaultTap and .listenOnly) work under
        // Accessibility trust; Input Monitoring is the alternative grant that lets
        // listen-only taps work in apps WITHOUT Accessibility. This app always requires
        // Accessibility (the Fn tap needs it), so no separate Input Monitoring grant is
        // needed or tracked.
        accessibilityGranted = AXIsProcessTrusted()

        if allGranted && !wasAllGranted {
            wasAllGranted = true
            onAllGranted?()
        }
    }

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    // MARK: - Requests

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneGranted = granted
        } else {
            openMicrophoneSettings()
        }
    }

    func requestAccessibility() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": false]
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - System Settings

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                if self.allGranted {
                    self.stopPolling()
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
