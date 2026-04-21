import Foundation
import UserNotifications

extension AppState {
    // MARK: - Duration Monitoring

    func startDurationChecks() {
        durationCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDuration()
            }
        }
    }

    func stopDurationChecks() {
        durationCheckTimer?.invalidate()
        durationCheckTimer = nil
    }

    private func checkDuration() {
        let duration = recorder.currentDuration

        if duration >= warningDuration && !warningShown {
            warningShown = true
            let remaining = Int(maxRecordingDuration - duration)
            toast.show(
                ToastMessage(
                    type: .warning,
                    title: "Recording Limit",
                    message: "Recording will stop in \(remaining / 60) min \(remaining % 60) sec"
                ))

            let content = UNMutableNotificationContent()
            content.title = "Recording Limit"
            content.body = "Recording will automatically stop in ~2 minutes"
            let request = UNNotificationRequest(
                identifier: "recording-warning", content: content, trigger: nil)
            Task {
                try? await UNUserNotificationCenter.current().add(request)
            }
        }

        if duration >= maxRecordingDuration {
            stopAndTranscribe()
        }
    }
}
