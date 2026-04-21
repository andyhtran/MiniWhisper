import SwiftUI

struct SettingsPopoverView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    // Local mirror of the UserDefaults-backed VAD toggle so SwiftUI re-renders
    // when flipped. VADSettings isn't @Observable — it's a plain wrapper.
    @State private var vadEnabled = VADSettings.enabled
    @State private var spokenSymbolsEnabled = SpokenSymbolsSettings.enabled

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Launch at Login")
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Spoken Symbols")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack {
                    Text("Convert spoken phrases like 'open bracket' into symbols")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { spokenSymbolsEnabled },
                            set: {
                                spokenSymbolsEnabled = $0
                                SpokenSymbolsSettings.enabled = $0
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            // Custom Endpoint only applies to the Custom transcription mode.
            // Local models (Parakeet / Whisper) run on-device and don't
            // need URL/key/model config or silence trimming, so the whole
            // section is hidden for them.
            if appState.transcriptionMode == .custom {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom Endpoint")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Endpoint URL")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField(
                            "https://api.example.com/v1/audio/transcriptions",
                            text: $appState.customProviderSettings.endpointURL
                        )
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
                        TextField(
                            "whisper-large-v3", text: $appState.customProviderSettings.modelName
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recordings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                OpenRecordingsFolderRow()
            }
        }
        .padding(12)
        .frame(width: 300)
        .onChange(of: appState.customProviderSettings) {
            appState.customProviderSettings.save()
        }
        .onAppear {
            launchManager.refresh()
            vadEnabled = VADSettings.enabled
            spokenSymbolsEnabled = SpokenSymbolsSettings.enabled
        }
    }
}

private struct OpenRecordingsFolderRow: View {
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

                Text("Open Recordings Folder")
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
