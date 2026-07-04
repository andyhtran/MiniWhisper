#if canImport(Sparkle) && ENABLE_SPARKLE
import AppKit
import Foundation
import Sparkle
import UserNotifications

/// Custom Sparkle user driver: every callback is folded into an UpdateState
/// that the menu-bar UI renders inline, replacing Sparkle's own alert and
/// progress windows entirely. No windows means no focus juggling for this
/// LSUIElement app — the class of bugs the old standard-driver setup needed
/// activate()/orderFrontRegardless() workarounds for.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel

    /// Pending acknowledgement for a not-found or error result. Routed
    /// through acknowledgePending() so the UI's dismiss action and the
    /// auto-dismiss timer can't both invoke Sparkle's one-shot block.
    private var pendingAcknowledgement: (() -> Void)?
    private var autoDismissTask: Task<Void, Never>?

    init(viewModel: UpdateViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Not reached in practice: the controller sets
        // automaticallyChecksForUpdates explicitly at startup, which tells
        // Sparkle the app manages that preference itself. Answer from the
        // saved preference just in case.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: UpdaterDefaults.savedAutoUpdateEnabled(),
            sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        let cancel = OneShotAction(cancellation)
        viewModel.state = .checking(.init(cancel: { cancel() }))
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let infoOnly = appcastItem.isInformationOnlyUpdate
        let infoURL = appcastItem.infoURL
        let updateChoice = OneShotReply(reply)
        viewModel.state = .updateAvailable(.init(
            version: appcastItem.displayVersionString,
            byteCount: appcastItem.contentLength > 0
                ? Int64(appcastItem.contentLength) : nil,
            install: {
                // Info-only updates must not be installed; the best we can
                // do is send the user to the release page.
                if infoOnly {
                    guard updateChoice.send(.dismiss) else { return }
                    if let infoURL { NSWorkspace.shared.open(infoURL) }
                } else {
                    updateChoice.send(.install)
                }
            },
            dismiss: { updateChoice.send(.dismiss) }))

        // A scheduled background check has no visible UI moment, so surface
        // discovery with a notification; tapping it opens the popover where
        // the banner lives (handled in AppDelegate). For user-initiated
        // checks the banner is already on screen — just drop any stale one.
        if state.userInitiated {
            clearUpdateNotification()
        } else {
            postUpdateAvailableNotification(
                version: appcastItem.displayVersionString)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes aren't rendered in the banner UI, and the appcast
        // doesn't link any, so this never fires.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // See showUpdateReleaseNotes.
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        pendingAcknowledgement = acknowledgement
        viewModel.state = .notFound(.init(
            acknowledge: { [weak self] in self?.acknowledgePending() }))
        // Sparkle only ends the session (and allows the next check) once
        // acknowledged, and the banner may never be seen if the popover is
        // closed — so acknowledge on a timer, which also auto-dismisses the
        // "up to date" banner.
        scheduleAutoDismiss(after: .seconds(5))
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        pendingAcknowledgement = acknowledgement
        viewModel.state = .failed(.init(
            message: error.localizedDescription,
            dismiss: { [weak self] in self?.acknowledgePending() }))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        let cancel = OneShotAction(cancellation)
        clearUpdateNotification()
        viewModel.state = .downloading(.init(
            cancel: { cancel() }, expectedLength: nil, receivedLength: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(
        _ expectedContentLength: UInt64
    ) {
        guard case .downloading(let downloading) = viewModel.state else { return }
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            receivedLength: 0))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloading(let downloading) = viewModel.state else { return }
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            receivedLength: downloading.receivedLength + length))
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The download only ever starts from an explicit Install click
        // (automatic downloads are disabled), so readiness is consent:
        // confirm immediately and let install → relaunch chain through
        // with no further prompts.
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        viewModel.state = .installing
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        // Not reached when the updater dies with the app (our case), but
        // Sparkle requires the acknowledgement if it ever is.
        acknowledgement()
        viewModel.state = .idle
    }

    func dismissUpdateInstallation() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        // Sparkle is tearing the session down; the acknowledgement (if any)
        // was already consumed on the path that got us here.
        pendingAcknowledgement = nil
        clearUpdateNotification()
        viewModel.state = .idle
    }

    // MARK: - Acknowledgement plumbing

    private func acknowledgePending() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let acknowledgement = pendingAcknowledgement else { return }
        pendingAcknowledgement = nil
        // Sparkle follows up with dismissUpdateInstallation, which resets
        // the state to idle.
        acknowledgement()
    }

    private func scheduleAutoDismiss(after duration: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.acknowledgePending()
        }
    }

    // MARK: - Update-available notification

    private func postUpdateAvailableNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "MiniWhisper \(version) is available. Click to update."
        let request = UNNotificationRequest(
            identifier: UpdateNotification.identifier, content: content,
            trigger: nil)
        // If notification permission was denied, this is silently dropped —
        // the menu banner still covers discovery.
        UNUserNotificationCenter.current().add(request)
    }

    private func clearUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(
            withIdentifiers: [UpdateNotification.identifier])
        center.removePendingNotificationRequests(
            withIdentifiers: [UpdateNotification.identifier])
    }
}

@MainActor
private final class OneShotAction {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func callAsFunction() {
        guard let action else { return }
        self.action = nil
        action()
    }
}

@MainActor
private final class OneShotReply<Value> {
    private var reply: ((Value) -> Void)?

    init(_ reply: @escaping (Value) -> Void) {
        self.reply = reply
    }

    @discardableResult
    func send(_ value: Value) -> Bool {
        guard let reply else { return false }
        self.reply = nil
        reply(value)
        return true
    }
}
#endif
