import SwiftUI

struct SettingsPopoverView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var launchManager = LaunchAtLoginManager.shared
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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Replacements")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack {
                    Text("Enable find-and-replace rules after transcription")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle("", isOn: $appState.replacementSettings.enabled)
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
                CustomEndpointSection()
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
        .onChange(of: appState.replacementSettings) {
            appState.replacementSettings.save()
        }
        .onAppear {
            launchManager.refresh()
            spokenSymbolsEnabled = SpokenSymbolsSettings.enabled
        }
    }
}

// MARK: - Custom Endpoint Section

// Edit-gated section: fields render as selectable read-only text by default
// and only swap in real TextFields while `isEditing` is true. This keeps
// accidental focus off text fields (select-all-on-focus can destroy values)
// and shrinks the window in which a field editor can be first responder when
// the user switches popovers — reducing the crash class documented in
// PopoverResponderReset.swift.
private struct CustomEndpointSection: View {
    @Environment(AppState.self) private var appState

    @State private var isEditing = false
    @State private var draftURL = ""
    @State private var draftAPIKey = ""
    @State private var draftModel = ""
    @State private var vadEnabled = VADSettings.enabled

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, apiKey, model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            fieldRow(label: "Endpoint URL") {
                if isEditing {
                    TextField(
                        "https://api.example.com/v1/audio/transcriptions",
                        text: $draftURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .url)
                    .onSubmit(confirm)
                } else {
                    ReadOnlyFieldDisplay(
                        text: appState.customProviderSettings.endpointURL,
                        placeholder: "Not set"
                    )
                }
            }

            fieldRow(label: "API Key (optional)") {
                if isEditing {
                    SecureField("sk-...", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit(confirm)
                } else {
                    ReadOnlyFieldDisplay(
                        text: maskedAPIKey(appState.customProviderSettings.apiKey),
                        placeholder: "None",
                        selectable: false
                    )
                }
            }

            fieldRow(label: "Model Name") {
                if isEditing {
                    TextField("whisper-large-v3", text: $draftModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .model)
                        .onSubmit(confirm)
                } else {
                    ReadOnlyFieldDisplay(
                        text: appState.customProviderSettings.modelName,
                        placeholder: "Not set"
                    )
                }
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
        .onAppear { vadEnabled = VADSettings.enabled }
    }

    private var header: some View {
        HStack {
            Text("Custom Endpoint")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            if isEditing {
                HStack(spacing: 6) {
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .keyboardShortcut(.cancelAction)

                    Button(action: confirm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Save")
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button(action: beginEditing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit")
            }
        }
    }

    private func fieldRow<Content: View>(
        label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func beginEditing() {
        draftURL = appState.customProviderSettings.endpointURL
        draftAPIKey = appState.customProviderSettings.apiKey
        draftModel = appState.customProviderSettings.modelName
        isEditing = true
        // Defer to let SwiftUI mount the TextFields before focus attaches.
        DispatchQueue.main.async {
            focusedField = .url
        }
    }

    private func confirm() {
        // Assign a new struct in one shot so @Observable / onChange fire once.
        var updated = appState.customProviderSettings
        updated.endpointURL = draftURL
        updated.apiKey = draftAPIKey
        updated.modelName = draftModel
        appState.customProviderSettings = updated
        focusedField = nil
        isEditing = false
    }

    private func cancel() {
        focusedField = nil
        isEditing = false
    }

    private func maskedAPIKey(_ key: String) -> String {
        key.isEmpty ? "" : String(repeating: "•", count: min(key.count, 32))
    }
}

private struct ReadOnlyFieldDisplay: View {
    let text: String
    let placeholder: String
    var selectable: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                } else if selectable {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
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
