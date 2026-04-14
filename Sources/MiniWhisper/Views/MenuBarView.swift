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
    @State private var showPicker = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Microphone", icon: "mic.fill")

            Button {
                showPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(appState.deviceManager.effectiveDeviceName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

                    if appState.deviceManager.inputMode == .systemDefault {
                        Text("System Default")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else if !appState.deviceManager.isSelectedDeviceAvailable {
                        Text("Unavailable")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
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
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                MicrophonePickerView()
            }
        }
    }
}

private struct MicrophonePickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Device")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 10)

            VStack(spacing: 2) {
                // System Default option
                MicPickerRow(
                    name: "System Default",
                    subtitle: appState.deviceManager.systemDefaultDeviceName,
                    isSelected: appState.deviceManager.inputMode == .systemDefault
                ) {
                    appState.deviceManager.selectSystemDefault()
                }

                if !appState.deviceManager.availableDevices.isEmpty {
                    Divider()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)

                    ForEach(appState.deviceManager.availableDevices) { device in
                        MicPickerRow(
                            name: device.name,
                            subtitle: nil,
                            isSelected: appState.deviceManager.inputMode == .specificDevice
                                && appState.deviceManager.selectedDeviceUID == device.uid
                        ) {
                            appState.deviceManager.selectDevice(device)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct MicPickerRow: View {
    let name: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
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
        HStack(spacing: 0) {
            Spacer()

            if appState.transcriptionMode == .custom {
                FooterButton(icon: "gearshape", label: "Config", color: appState.customProviderSettings.isConfigured ? .accentColor : .orange) {
                    showCustomConfig.toggle()
                }
                .popover(isPresented: $showCustomConfig, arrowEdge: .bottom) {
                    CustomEndpointConfigView()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            FooterButton(icon: modelPickerIcon, label: "Model", color: appState.transcriptionMode == .english ? .secondary : .accentColor) {
                showModelPicker.toggle()
            }
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView()
            }

            FooterButton(icon: "folder.fill", label: "Files", color: .secondary) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path)
            }

            FooterButton(icon: "arrow.left.arrow.right", label: "Replace", color: appState.replacementSettings.enabled ? .primary : .secondary) {
                showReplacements.toggle()
            }
            .popover(isPresented: $showReplacements, arrowEdge: .bottom) {
                ReplacementsView(
                    settings: Binding(
                        get: { appState.replacementSettings },
                        set: { appState.replacementSettings = $0 }
                    ),
                    onSave: { appState.replacementSettings.save() }
                )
            }

            FooterButton(icon: "clock.arrow.circlepath", label: "History", color: .secondary) {
                showHistory.toggle()
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                HistoryPopoverView()
            }

            FooterButton(icon: launchManager.isEnabled ? "power.circle.fill" : "power.circle", label: "Login", color: launchManager.isEnabled ? .accentColor : .secondary) {
                showLaunchAtLogin.toggle()
            }
            .popover(isPresented: $showLaunchAtLogin, arrowEdge: .bottom) {
                LaunchAtLoginPopoverView()
            }

            FooterButton(icon: "xmark.circle", label: "Quit", color: .red) {
                NSApplication.shared.terminate(nil)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
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

private struct FooterButton: View {
    let icon: String
    let label: String
    var color: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(color)
                    .frame(width: 24, height: 20)

                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

                HStack(spacing: 4) {
                    Text(formatDate(recording.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))

                    if recording.transcription != nil {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text(recording.configuration.voiceModel)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }

            Spacer(minLength: 12)

            if recording.transcription != nil {
                HStack(spacing: 6) {
                    if recording.canRetranscribeAsNew && isHovering && !copied {
                        Button {
                            appState.retranscribeAsNew(recording)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundColor(isRetranscribeDisabled ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetranscribeDisabled)
                        .help("Re-transcribe with current model")
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }

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

    private var isRetranscribeDisabled: Bool {
        appState.recorder.state.isRecording || appState.recorder.state == .processing
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Renders all menu bar icon states into NSImage so the view identity stays
/// stable across state transitions (no flicker). SF Symbols are rasterized
/// through NSImage(symbolName:) for idle/processing; the recording state
/// draws custom animated bars.
enum MenuBarIconRenderer {
    // Bar geometry for the recording meter
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 16
    private static let sideScale: CGFloat = 0.65
    private static let minFraction: CGFloat = 0.2

    static func render(state: RecordingState, meterLevel: Double) -> NSImage {
        switch state {
        case .recording:
            return renderMeterBars(level: meterLevel)
        case .processing:
            return renderSymbol("waveform.badge.ellipsis")
        default:
            return renderSymbol("waveform")
        }
    }

    /// Render an SF Symbol as a template NSImage sized for the menu bar.
    private static func renderSymbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            return configured
        }
        // Fallback — should never happen with known symbol names
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    /// Draw three rounded red bars whose height tracks the mic level.
    private static func renderMeterBars(level: Double) -> NSImage {
        let totalWidth = barWidth * 3 + barSpacing * 2
        let size = NSSize(width: totalWidth, height: maxHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            let effectiveLevel = minFraction + CGFloat(level) * (1.0 - minFraction)

            let scales: [CGFloat] = [sideScale, 1.0, sideScale]
            for (i, scale) in scales.enumerated() {
                let barHeight = max(maxHeight * effectiveLevel * scale, barWidth)
                let x = CGFloat(i) * (barWidth + barSpacing)
                let y = (maxHeight - barHeight) / 2.0
                let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                NSColor.systemRed.setFill()
                path.fill()
            }
            return true
        }

        image.isTemplate = false
        return image
    }
}
