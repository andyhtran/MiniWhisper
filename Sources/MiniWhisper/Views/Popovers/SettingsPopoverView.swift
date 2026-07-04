import AppKit
import SwiftUI

struct SettingsPopoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.updaterController) private var updaterController
    @State private var errorToastsEnabled = GeneralSettings.errorToastsEnabled
    @State private var vadEnabled = VADSettings.enabled
    @State private var hasCustomPrompt = CleanupPromptStore.hasCustomPrompt

    let onOpenFullSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPopoverSectionHeader(title: "Quick Settings", icon: "gearshape")

            errorNotificationsRow
            trimLongSilencesRow

            if appState.editModeBehavior.selectionEnabled {
                selectedTextActionRow
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SettingsPopoverActionRow(
                    title: "Open MiniWhisper Folder",
                    icon: "folder"
                ) {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path
                    )
                }

                if !appState.editModeBehavior.isOff {
                    cleanupPromptRow
                }
            }

            Divider()

            Button(action: onOpenFullSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 16)
                    Text("Open Settings...")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SettingsPopoverActionRow(
                title: updateCheckTitle,
                icon: "arrow.clockwise",
                disabled: updateCheckDisabled
            ) {
                guard updaterController?.updateViewModel.state.allowsManualCheck == true else {
                    return
                }
                updaterController?.checkForUpdates(nil)
            }

            AppVersionFooter()
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            errorToastsEnabled = GeneralSettings.errorToastsEnabled
            vadEnabled = VADSettings.enabled
            hasCustomPrompt = CleanupPromptStore.hasCustomPrompt
        }
    }

    private var updateCheckTitle: String {
        switch updaterController?.updateViewModel.state ?? .idle {
        case .idle, .notFound:
            "Check for Updates"
        case .checking:
            "Checking for Updates..."
        case .updateAvailable:
            "Update Available"
        case .downloading:
            "Downloading Update..."
        case .extracting:
            "Preparing Update..."
        case .installing:
            "Installing Update..."
        case .failed:
            "Retry Update Check"
        }
    }

    private var updateCheckDisabled: Bool {
        guard let updaterController, updaterController.isAvailable else {
            return true
        }
        return !updaterController.updateViewModel.state.allowsManualCheck
    }

    private var errorNotificationsRow: some View {
        HStack {
            InfoLabel(
                title: "Show error notifications",
                text: "Show a toast when recording, transcription, or other app actions fail."
            )
            .font(.system(size: 13))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { errorToastsEnabled },
                    set: { enabled in
                        errorToastsEnabled = enabled
                        GeneralSettings.errorToastsEnabled = enabled
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private var trimLongSilencesRow: some View {
        HStack {
            Text("Trim long silences")
                .font(.system(size: 13))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { vadEnabled },
                    set: { enabled in
                        vadEnabled = enabled
                        VADSettings.enabled = enabled
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private var selectedTextActionRow: some View {
        HStack(spacing: 8) {
            InfoLabel(
                title: "Selected text action",
                text: "Clean automatically rewrites selected text immediately. Dictate instruction lets you speak how to change it."
            )
            .font(.system(size: 13))

            Spacer(minLength: 8)

            Picker(
                "",
                selection: Binding(
                    get: { appState.voiceEditEnabled },
                    set: { enabled in
                        appState.voiceEditEnabled = enabled
                        EditModeSettings.voiceEdit = enabled
                    }
                )
            ) {
                Text("Clean automatically").tag(false)
                Text("Dictate instruction").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 145)
        }
    }

    private var cleanupPromptRow: some View {
        HStack(spacing: 8) {
            SettingsPopoverActionRow(
                title: "Edit Cleanup Prompt",
                icon: "doc.text"
            ) {
                editCleanupPrompt()
            }

            if hasCustomPrompt {
                Button("Reset", action: confirmResetCleanupPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func editCleanupPrompt() {
        do {
            try CleanupPromptStore.seedIfMissing()
            NSWorkspace.shared.open(CleanupPromptStore.fileURL)
            hasCustomPrompt = CleanupPromptStore.hasCustomPrompt
        } catch {
            appState.toast.showError(
                title: "Couldn't Open Prompt File",
                message: error.localizedDescription
            )
        }
    }

    private func confirmResetCleanupPrompt() {
        let alert = NSAlert()
        alert.messageText = "Reset cleanup prompt?"
        alert.informativeText =
            "This overwrites your edits to cleanup-prompt.md with the bundled default. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try CleanupPromptStore.resetToDefault()
            hasCustomPrompt = false
        } catch {
            appState.toast.showError(
                title: "Reset Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct SettingsPopoverSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .foregroundStyle(.secondary)
    }
}

private struct SettingsPopoverActionRow: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
