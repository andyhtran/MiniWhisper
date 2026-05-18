import SwiftUI

struct SettingsPopoverView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    @State private var editModeBehavior = EditModeSettings.behavior
    @State private var errorToastsEnabled = GeneralSettings.errorToastsEnabled
    @State private var vadEnabled = VADSettings.enabled
    @State private var autoUpdateEnabled = (NSApp.delegate as? AppDelegate)?.updaterController
        .automaticallyChecksForUpdates ?? true

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("General")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack {
                    Text("Start MiniWhisper when you log in")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { launchManager.isEnabled },
                            set: { launchManager.isEnabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                HStack {
                    Text("Check for updates automatically")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { autoUpdateEnabled },
                            set: {
                                autoUpdateEnabled = $0
                                (NSApp.delegate as? AppDelegate)?.updaterController
                                    .automaticallyChecksForUpdates = $0
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                HStack(spacing: 4) {
                    Text("Show error notifications")
                        .font(.system(size: 13))
                    InfoBadge(text: "Show a toast when something fails — recording errors, transcription failures, etc. Turn off if you'd rather the app stay quiet on errors.")
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { errorToastsEnabled },
                            set: {
                                errorToastsEnabled = $0
                                GeneralSettings.errorToastsEnabled = $0
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                HStack {
                    Text("Trim long silences")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { vadEnabled },
                            set: {
                                vadEnabled = $0
                                VADSettings.enabled = $0
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            Divider()

            // AI editing mode leads — chunkier picker before the toggles.
            VStack(alignment: .leading, spacing: 10) {
                Text("Editing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack(spacing: 4) {
                    Text("AI editing mode")
                        .font(.system(size: 13))
                    InfoBadge(text: "Selection — clean up selected text with AI. Cleanup — polish recordings before pasting.")
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { editModeBehavior },
                            set: {
                                editModeBehavior = $0
                                EditModeSettings.behavior = $0
                                appState.editModeBehavior = $0
                            }
                        )
                    ) {
                        ForEach(EditModeBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                if editModeBehavior.selectionEnabled {
                    HStack(spacing: 4) {
                        Text("Voice instruction")
                            .font(.system(size: 13))
                        InfoBadge(text: "Speak an editing instruction (e.g. \"make this formal\") instead of auto-cleaning the selection.")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appState.voiceEditEnabled },
                                set: {
                                    appState.voiceEditEnabled = $0
                                    EditModeSettings.voiceEdit = $0
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                HStack(spacing: 4) {
                    Text("Enable replacements")
                        .font(.system(size: 13))
                    InfoBadge(text: "Apply find-and-replace rules to every transcription")
                    Spacer()
                    Toggle("", isOn: $appState.replacementSettings.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if appState.replacementSettings.enabled {
                    ClaudeSkillRow()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                OpenMiniWhisperFolderRow()

                if !editModeBehavior.isOff {
                    CleanupPromptRow()
                }
            }

        }
        .padding(12)
        .frame(width: 300)
        .onChange(of: appState.replacementSettings) {
            appState.replacementSettings.save()
        }
        .onAppear {
            launchManager.refresh()
            editModeBehavior = EditModeSettings.behavior
            errorToastsEnabled = GeneralSettings.errorToastsEnabled
            vadEnabled = VADSettings.enabled
        }
    }
}

// MARK: - Claude Code Skill Row
//
// Rendered as a sub-row inside the Replacements section. The skill writes
// rules into `replacements.json`, so it only makes sense to surface when
// replacements themselves are enabled — otherwise rules would land in the
// file but never apply to transcriptions.

private struct ClaudeSkillRow: View {
    @Environment(AppState.self) private var appState
    private let manager = ClaudeSkillManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Claude Code skill")
                            .font(.system(size: 13))
                        InfoBadge(text: "Allow Claude to add replacements automatically using /mw-replace")
                    }
                    subtitle
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { manager.isEnabled },
                        set: { toggle($0) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!manager.claudeCodeInstalled || manager.hasConflict)
            }

            actionRow
        }
        .onAppear { manager.refresh() }
    }

    // Hidden entirely in the healthy `.upToDate` state — we only surface text
    // when the user needs to know or act on something.
    @ViewBuilder
    private var subtitle: some View {
        if !manager.claudeCodeInstalled {
            Text("Claude Code not detected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if manager.hasConflict {
            Text("Another skill with this name already exists")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let statusText {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if manager.hasConflict {
            HStack {
                Spacer()
                Button("Show in Finder") { manager.revealConflictInFinder() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 11))
        } else if manager.claudeCodeInstalled, let updateButtonLabel {
            HStack {
                Spacer()
                Button(updateButtonLabel, action: applyUpdate)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 11))
        }
    }

    private var statusText: String? {
        switch manager.syncStatus {
        case .upToDate: return nil
        case .updateAvailable: return "Update available"
        case .modified: return "Modified"
        case .modifiedAndUpdateAvailable: return "Modified · update available"
        }
    }

    private var updateButtonLabel: String? {
        switch manager.syncStatus {
        case .upToDate: return nil
        case .updateAvailable: return "Update"
        case .modified: return "Reset to default"
        case .modifiedAndUpdateAvailable: return "Update (overwrites edits)"
        }
    }

    private func toggle(_ on: Bool) {
        do {
            try on ? manager.enable() : manager.disable()
        } catch {
            appState.toast.showError(
                title: on ? "Couldn't Enable Skill" : "Couldn't Disable Skill",
                message: error.localizedDescription
            )
            manager.refresh()
        }
    }

    private func applyUpdate() {
        do {
            try manager.applyBundledVersion()
        } catch {
            appState.toast.showError(
                title: "Update Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct OpenMiniWhisperFolderRow: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                Text("Open MiniWhisper Folder")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Cleanup Prompt Row
//
// Edit + Reset affordances for the cleanup-pass system prompt. Only
// rendered when the AI editing mode includes auto-cleanup (caller gates
// visibility), so the row is contextually relevant when shown. Reset
// hides itself further when the on-disk prompt matches the bundled
// default — no point offering Reset when there's nothing to reset to.

private struct CleanupPromptRow: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false
    @State private var hasCustomPrompt = CleanupPromptStore.hasCustomPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: edit) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Text("Edit cleanup prompt")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isHovering
                                ? Color.primary.opacity(0.06) : Color.primary.opacity(0.04))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }

            if hasCustomPrompt {
                HStack {
                    Spacer()
                    Button("Reset to default", action: confirmReset)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 11))
                }
            }
        }
        .onAppear { hasCustomPrompt = CleanupPromptStore.hasCustomPrompt }
    }

    private func edit() {
        do {
            try CleanupPromptStore.seedIfMissing()
            NSWorkspace.shared.open(CleanupPromptStore.fileURL)
            // Re-check on next appear in case the user edited and saved
            // — Reset visibility tracks the on-disk diff.
            hasCustomPrompt = CleanupPromptStore.hasCustomPrompt
        } catch {
            appState.toast.showError(
                title: "Couldn't Open Prompt File",
                message: error.localizedDescription
            )
        }
    }

    private func confirmReset() {
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
