import SwiftUI

struct ModelPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var editModel: EditModeModel = EditModeSettings.model

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 6) {
            // Edit model section ranks above transcription when any AI
            // editing is on — those users invoke it more often than they
            // switch transcription models, so it's the more useful
            // default-top.
            if !appState.editModeBehavior.isOff {
                editModelSection
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            transcriptionModelSection
        }
        .padding(12)
        .frame(width: 320)
        .onChange(of: appState.customProviderSettings) {
            appState.customProviderSettings.save()
        }
        .onChange(of: appState.customEditProviderSettings) {
            appState.customEditProviderSettings.save()
        }
        .onAppear {
            editModel = EditModeSettings.model
        }
    }

    @ViewBuilder
    private var transcriptionModelSection: some View {
        @Bindable var appState = appState

        Text("Transcription Model")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.top, !appState.editModeBehavior.isOff ? 4 : 0)

        VStack(spacing: 2) {
            ModelRow(
                icon: "bolt.fill",
                title: "Default",
                subtitle: "English + 20 European languages",
                badge: nil,
                isSelected: appState.transcriptionMode == .default
            ) {
                appState.switchTranscriptionMode(to: .default)
            }

            ModelRow(
                icon: "globe",
                title: "Multilingual",
                subtitle: "Auto-detect language",
                badge: appState.whisper.modelExists ? nil : "547 MB",
                isSelected: appState.transcriptionMode == .multilingual
            ) {
                appState.switchTranscriptionMode(to: .multilingual)
            }

            ModelRow(
                icon: "server.rack",
                title: "Custom",
                subtitle: "OpenAI-compatible endpoint",
                badge: nil,
                isSelected: appState.transcriptionMode == .custom
            ) {
                appState.switchTranscriptionMode(to: .custom)
            }
        }

        // Inline configuration for the Custom row. Local models (Parakeet
        // / Whisper) run on-device and need no URL/key/model config or
        // silence trimming, so the whole block only renders for Custom.
        if appState.transcriptionMode == .custom {
            Divider()
                .padding(.horizontal, 10)
                .padding(.top, 4)
            CustomEndpointSection()
                .padding(.horizontal, 10)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var editModelSection: some View {
        Text("Edit Model")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 10)

        VStack(spacing: 2) {
            ModelRow(
                icon: "bolt.horizontal.fill",
                title: "Codex CLI",
                subtitle: "OpenAI · \(EditModeModel.gpt5Mini.rawValue)",
                badge: nil,
                isSelected: editModel == .gpt5Mini
            ) {
                selectEditModel(.gpt5Mini)
            }

            ModelRow(
                icon: "hare.fill",
                title: "Claude Code",
                subtitle: "Anthropic · \(EditModeModel.claudeHaiku45.rawValue)",
                badge: nil,
                isSelected: editModel == .claudeHaiku45
            ) {
                selectEditModel(.claudeHaiku45)
            }

            ModelRow(
                icon: "server.rack",
                title: "Custom",
                subtitle: "OpenAI-compatible endpoint",
                badge: nil,
                isSelected: editModel == .custom
            ) {
                selectEditModel(.custom)
            }
        }

        // Inline configuration for the Custom edit row, mirroring the
        // transcription side. Only renders when Custom is actually
        // selected — the built-in models need no URL/key/model config.
        if editModel == .custom {
            Divider()
                .padding(.horizontal, 10)
                .padding(.top, 4)
            CustomEditEndpointSection()
                .padding(.horizontal, 10)
                .padding(.top, 4)
        }
    }

    private func selectEditModel(_ model: EditModeModel) {
        editModel = model
        EditModeSettings.model = model
    }
}

private struct ModelRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
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

            // Endpoint URL and API Key only render while editing — the
            // collapsed view is just the model name, since that's what
            // identifies which custom backend is in use day-to-day. The
            // URL/key are setup details, not status.
            if isEditing {
                fieldRow(label: "Endpoint URL") {
                    TextField(
                        "https://api.example.com/v1/audio/transcriptions",
                        text: $draftURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .url)
                    .onSubmit(confirm)
                }

                fieldRow(label: "API Key (optional)") {
                    SecureField("sk-...", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit(confirm)
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
            Text("Configuration")
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
        // Store the user's input verbatim — normalization happens at
        // request time inside `CustomProvider.transcribe`, so the field
        // shows whatever the user typed.
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

// MARK: - Custom Edit Endpoint Section

/// Edit-side mirror of `CustomEndpointSection`. Same edit-gated pattern
/// — fields render as selectable read-only text by default, swap to
/// real `TextField`s only while the user is actively editing — for the
/// same reasons (avoid select-all-on-focus value loss; minimize the
/// window in which a field editor can be first responder when popovers
/// switch, which has triggered the crash class documented in
/// PopoverResponderReset.swift).
private struct CustomEditEndpointSection: View {
    @Environment(AppState.self) private var appState

    @State private var isEditing = false
    @State private var draftURL = ""
    @State private var draftAPIKey = ""
    @State private var draftModel = ""

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url, apiKey, model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isEditing {
                fieldRow(label: "Endpoint URL") {
                    TextField(
                        "https://api.example.com/v1/chat/completions",
                        text: $draftURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .url)
                    .onSubmit(confirm)
                }

                fieldRow(label: "API Key (optional)") {
                    SecureField("sk-...", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit(confirm)
                }
            }

            fieldRow(label: "Model Name") {
                if isEditing {
                    TextField("gpt-4o-mini", text: $draftModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .model)
                        .onSubmit(confirm)
                } else {
                    ReadOnlyFieldDisplay(
                        text: appState.customEditProviderSettings.modelName,
                        placeholder: "Not set"
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Configuration")
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
        draftURL = appState.customEditProviderSettings.endpointURL
        draftAPIKey = appState.customEditProviderSettings.apiKey
        draftModel = appState.customEditProviderSettings.modelName
        isEditing = true
        DispatchQueue.main.async {
            focusedField = .url
        }
    }

    private func confirm() {
        var updated = appState.customEditProviderSettings
        updated.endpointURL = draftURL
        updated.apiKey = draftAPIKey
        updated.modelName = draftModel
        appState.customEditProviderSettings = updated
        focusedField = nil
        isEditing = false
    }

    private func cancel() {
        focusedField = nil
        isEditing = false
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
