import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            RecordingHeaderView()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider()
                .padding(.horizontal, 12)

            if !appState.permissions.allGranted {
                PermissionsBanner()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }

            VStack(spacing: 20) {
                MicrophoneSection()
                ShortcutSection()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .padding(.horizontal, 12)

            StatsBarView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 12)

            FooterBarView()
        }
        .frame(width: 340)
        .background(.ultraThickMaterial)
        .environment(appState)
    }
}

// MARK: - Recording Header

private struct RecordingHeaderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13))
                .foregroundColor(statusColor)
                .frame(width: 20)
                .animation(.easeInOut(duration: 0.15), value: statusIcon)

            Text(statusText)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            if appState.recorder.state.isRecording {
                Text(formatDuration(appState.recorder.currentDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if appState.isModelDownloading {
                HStack(spacing: 6) {
                    ProgressView(value: appState.modelDownloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                        .controlSize(.small)
                    Text("\(Int(appState.modelDownloadProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else if !appState.isModelLoaded {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var statusIcon: String {
        if !appState.permissions.allGranted {
            return "exclamationmark.triangle.fill"
        }
        switch appState.recorder.state {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .processing: return "waveform.badge.ellipsis"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if !appState.permissions.allGranted {
            return .orange
        }
        switch appState.recorder.state {
        case .idle: return .secondary
        case .recording: return .red
        case .processing: return .orange
        case .error: return .red
        }
    }

    private var statusText: String {
        if !appState.permissions.allGranted {
            return "Permissions Required"
        }
        switch appState.recorder.state {
        case .idle:
            if appState.isModelDownloading { return "Downloading Model..." }
            if appState.transcriptionMode == .custom && !appState.customProviderSettings.isConfigured {
                return "Configure Endpoint"
            }
            return appState.isModelLoaded ? "Ready" : "Loading Model..."
        case .recording: return "Recording"
        case .processing: return "Transcribing..."
        case .error(let msg): return msg
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let icon: String
    var iconColor: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(iconColor)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }
}

// MARK: - Microphone Section

private struct MicrophoneSection: View {
    @Environment(AppState.self) private var appState
    @State private var isRefreshHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Microphone", icon: "mic.fill")

                Spacer()

                Button {
                    appState.recorder.refreshDeviceName()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(isRefreshHovering ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh microphone")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isRefreshHovering = hovering
                    }
                }
            }

            HStack(spacing: 8) {
                Text(appState.recorder.systemDefaultDeviceName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Text("System Default")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.08))
            )
        }
    }
}

// MARK: - Shortcut Section

private struct ShortcutSection: View {
    @Environment(AppState.self) private var appState
    @State private var isEditing = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Shortcut", icon: "command")

            if isEditing {
                HStack(spacing: 8) {
                    ShortcutRecorderView(shortcut: Binding(
                        get: { CustomShortcutStorage.get(.toggleRecording) },
                        set: { newShortcut in
                            CustomShortcutStorage.set(newShortcut, for: .toggleRecording)
                            appState.reloadShortcuts()
                            isEditing = false
                        }
                    ))

                    Spacer()

                    Button {
                        isEditing = false
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.08))
                )
            } else {
                Button {
                    isEditing = true
                } label: {
                    HStack(spacing: 8) {
                        Text("Toggle Recording")
                            .font(.system(size: 13))

                        Spacer(minLength: 12)

                        if let shortcut = CustomShortcutStorage.get(.toggleRecording) {
                            Text(shortcut.compactDisplayString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not Set")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
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
    }
}

// MARK: - Permissions Banner

private struct PermissionsBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Permissions Needed", icon: "exclamationmark.shield.fill", iconColor: .orange)

            VStack(spacing: 4) {
                if !appState.permissions.accessibilityGranted {
                    PermissionRow(
                        icon: "keyboard",
                        label: "Accessibility",
                        detail: "Required for global hotkeys"
                    ) {
                        appState.permissions.openAccessibilitySettings()
                    }
                }

                if !appState.permissions.microphoneGranted {
                    PermissionRow(
                        icon: "mic.slash",
                        label: "Microphone",
                        detail: "Required for recording"
                    ) {
                        Task { await appState.permissions.requestMicrophone() }
                    }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let label: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("Grant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.orange.opacity(0.08) : Color.orange.opacity(0.04))
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

// MARK: - Footer Bar

private struct FooterBarView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    @State private var showHistory = false
    @State private var showReplacements = false
    @State private var showModelPicker = false
    @State private var showCustomConfig = false
    @State private var showLaunchAtLogin = false

    var body: some View {
        HStack(spacing: 16) {
            Spacer()

            if appState.transcriptionMode == .custom {
                Button {
                    showCustomConfig.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(appState.customProviderSettings.isConfigured ? .accentColor : .orange)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Configure Custom Endpoint")
                .popover(isPresented: $showCustomConfig, arrowEdge: .bottom) {
                    CustomEndpointConfigView()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            Button {
                showModelPicker.toggle()
            } label: {
                Image(systemName: modelPickerIcon)
                    .font(.system(size: 14))
                    .foregroundColor(appState.transcriptionMode == .english ? .secondary : .accentColor)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Transcription Model")
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView()
            }

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path)
            } label: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button {
                showReplacements.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14))
                    .foregroundColor(appState.replacementSettings.enabled ? .primary : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Text Replacements")
            .popover(isPresented: $showReplacements, arrowEdge: .bottom) {
                ReplacementsView(
                    settings: Binding(
                        get: { appState.replacementSettings },
                        set: { appState.replacementSettings = $0 }
                    ),
                    onSave: { appState.replacementSettings.save() }
                )
            }

            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Recent History")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                HistoryPopoverView()
            }

            Button {
                showLaunchAtLogin.toggle()
            } label: {
                Image(systemName: launchManager.isEnabled ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 14))
                    .foregroundColor(launchManager.isEnabled ? .accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Start on Login")
            .popover(isPresented: $showLaunchAtLogin, arrowEdge: .bottom) {
                LaunchAtLoginPopoverView()
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Quit MiniWhisper")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.15), value: appState.transcriptionMode)
        .onAppear {
            launchManager.refresh()
        }
    }

    private var modelPickerIcon: String {
        switch appState.transcriptionMode {
        case .english: return "waveform"
        case .multilingual: return "globe"
        case .custom: return "server.rack"
        }
    }
}

private struct LaunchAtLoginPopoverView: View {
    @StateObject private var launchManager = LaunchAtLoginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch at Login")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Toggle(
                "Start MiniWhisper when you log in",
                isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.isEnabled = $0 }
                )
            )
            .toggleStyle(.switch)
            .font(.system(size: 13))
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            launchManager.refresh()
        }
    }
}

// MARK: - Custom Endpoint Config

private struct CustomEndpointConfigView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Endpoint")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Endpoint URL")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("https://api.example.com/v1/audio/transcriptions", text: $appState.customProviderSettings.endpointURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key (optional)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    SecureField("sk-...", text: $appState.customProviderSettings.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Model Name")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("whisper-large-v3", text: $appState.customProviderSettings.modelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onChange(of: appState.customProviderSettings) {
            appState.customProviderSettings.save()
        }
    }
}

// MARK: - History Popover

private struct HistoryPopoverView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 10)

            if appState.recordingStore.recentHistoryItems.isEmpty {
                Text("No recent transcripts")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
                    .italic()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(appState.recordingStore.recentHistoryItems) { recording in
                        HistoryPopoverRow(recording: recording)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct HistoryPopoverRow: View {
    @Environment(AppState.self) private var appState
    let recording: Recording
    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Group {
            if let text = recording.transcription?.text {
                Button {
                    appState.pasteboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: copied)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryText)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundColor(recording.transcription != nil ? .primary : .secondary)

                Text(formatDate(recording.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer(minLength: 12)

            if recording.transcription != nil {
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 15))
                        .transition(.scale.combined(with: .opacity))
                } else if isHovering {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            } else if recording.status == .cancelled {
                if recording.canRetranscribe {
                    Button("Re-transcribe") {
                        appState.retranscribe(recording)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isReTranscribeDisabled ? .secondary : .accentColor)
                    .disabled(isReTranscribeDisabled)
                } else {
                    Text("Audio expired")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var primaryText: String {
        if let text = recording.transcription?.text {
            return text
        }
        if recording.status == .cancelled {
            return "Canceled recording"
        }
        return "No transcription"
    }

    private var isReTranscribeDisabled: Bool {
        recording.canRetranscribe == false || appState.recorder.state.isRecording || appState.recorder.state == .processing
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: RecordingState

    var body: some View {
        switch state {
        case .recording:
            Image(systemName: "waveform.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
        case .processing:
            Image(systemName: "waveform.badge.ellipsis")
        default:
            Image(systemName: "waveform")
        }
    }
}
