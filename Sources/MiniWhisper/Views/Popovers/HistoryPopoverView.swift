import AppKit
import SwiftUI

// MARK: - History Popover

struct HistoryPopoverView: View {
    @Environment(AppState.self) private var appState
    @State private var visibleLimit = 3

    private var items: [Recording] {
        appState.recordingStore.historyItems(limit: visibleLimit)
    }

    private var hasMore: Bool {
        visibleLimit < appState.recordingStore.totalHistoryItemCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 10)

            if items.isEmpty {
                Text("No recent transcripts")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
                    .italic()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { recording in
                        HistoryPopoverRow(recording: recording)
                    }

                    if hasMore {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                visibleLimit += 5
                            }
                        } label: {
                            Text("Show More")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
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
            if let copyTarget {
                Button {
                    appState.pasteboard.copy(copyTarget)
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

    private var isSelectionCleanup: Bool {
        recording.cleanup != nil && recording.transcription == nil && recording.editMode == nil
    }

    private var copyTarget: String? {
        if let editMode = recording.editMode { return editMode.editedResult }
        if isSelectionCleanup { return recording.cleanup?.cleanedText }
        return recording.transcription?.text
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if recording.editMode != nil {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    } else if recording.cleanup != nil {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    Text(primaryText)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .foregroundColor(hasContent ? .primary : .secondary)
                }

                HStack(spacing: 4) {
                    Text(formatDate(recording.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))

                    if let metaSuffix {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text(metaSuffix)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 12)

            if recording.transcription != nil || isSelectionCleanup {
                HStack(spacing: 6) {
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

                        rowActionsMenu
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
        if let edited = recording.editMode?.editedResult {
            return edited
        }
        if isSelectionCleanup, let cleaned = recording.cleanup?.cleanedText {
            return cleaned
        }
        if let text = recording.transcription?.text {
            return text
        }
        if recording.status == .cancelled {
            return "Canceled recording"
        }
        return "No transcription"
    }

    private var hasContent: Bool {
        recording.editMode != nil || recording.transcription != nil || isSelectionCleanup
    }

    /// Metadata suffix after the timestamp. Latency comes before the
    /// model name everywhere it's surfaced so the user can scan how
    /// long a given pass took before noticing which model ran it
    /// (`Edit · 2.6s · Codex CLI · "instruction"`,
    /// `Cleanup: 1.2s · Claude Code`). The friendly name swaps in for
    /// the technical model identifier — full detail still lives in
    /// metadata.json (reachable via the row's "Show metadata" action).
    private var metaSuffix: String? {
        if let editMode = recording.editMode {
            var parts = ["Edit"]
            if let editDuration = editMode.editDuration {
                parts.append(formatEditDuration(editDuration))
            }
            parts.append(friendlyEditModelName(
                backend: EditModeBackend(rawValue: editMode.backend),
                model: editMode.backendModel))
            if let instruction = recording.transcription?.text, !instruction.isEmpty {
                parts.append("\u{201C}\(instruction)\u{201D}")
            }
            return parts.joined(separator: " · ")
        }
        if isSelectionCleanup, let cleanup = recording.cleanup {
            var parts = ["Selection"]
            if let duration = cleanup.cleanupDuration, duration > 0 {
                parts.append(formatEditDuration(duration))
            }
            parts.append(friendlyEditModelName(
                backend: nil, model: cleanup.backendModel))
            return parts.joined(separator: " · ")
        }
        if let transcription = recording.transcription {
            var parts: [String] = []
            if let cleanup = recording.cleanup {
                // Voice model intentionally hidden on cleanup rows — the
                // polish step is what cleanup users care about; full
                // detail is in metadata.json.
                let total = transcription.transcriptionDuration
                    + (cleanup.cleanupDuration ?? 0)
                if total > 0 {
                    parts.append(formatEditDuration(total))
                }
                parts.append(friendlyEditModelName(
                    backend: nil, model: cleanup.backendModel))
            } else {
                // Plain voice: latency before the transcription model,
                // mirroring the edit/cleanup pattern.
                if transcription.transcriptionDuration > 0 {
                    parts.append(formatEditDuration(transcription.transcriptionDuration))
                }
                parts.append(friendlyVoiceModelName(
                    provider: recording.configuration.provider,
                    model: recording.configuration.voiceModel))
            }
            return parts.joined(separator: " · ")
        }
        return nil
    }

    /// New edit-mode entries carry an explicit backend tag — authoritative.
    /// Legacy entries and cleanup entries (which never stored a backend)
    /// fall back to a prefix sniff on the model string; unknown values
    /// land on "Custom" since that's the only third option in the picker.
    private func friendlyEditModelName(backend: EditModeBackend?, model: String) -> String {
        if let backend {
            switch backend {
            case .claudeCli: return "Claude Code"
            case .codexCli: return "Codex CLI"
            case .customApi: return "Custom"
            }
        }
        let lower = model.lowercased()
        if lower.hasPrefix("claude") { return "Claude Code" }
        if lower.hasPrefix("gpt") { return "Codex CLI" }
        return "Custom"
    }

    /// Friendly transcription label. New recordings carry an explicit
    /// `provider` tag (the `TranscriptionMode` raw value) — authoritative,
    /// so a custom-endpoint Whisper model no longer reads as
    /// "Multilingual". Legacy entries predating that field fall back to
    /// a prefix sniff on the model string; in that fallback, custom
    /// users whose model name starts with `whisper-` may still read as
    /// "Multilingual" — accept that since metadata.json has the truth.
    private func friendlyVoiceModelName(provider: String?, model: String) -> String {
        if let provider, let mode = TranscriptionMode(rawValue: provider) {
            switch mode {
            case .default: return "Default"
            case .multilingual: return "Multilingual"
            case .custom: return "Custom"
            }
        }
        let lower = model.lowercased()
        if lower.hasPrefix("parakeet") { return "Default" }
        if lower.hasPrefix("whisper") { return "Multilingual" }
        return "Custom"
    }

    /// Hover-revealed overflow menu. Re-transcribe is conditional on
    /// the audio still existing (the retention sweep can prune it);
    /// "Show metadata" opens the recording's metadata.json directly so
    /// the user can inspect the full technical identifiers that the
    /// abbreviated UI labels collapse over; "Show in Finder" reveals
    /// the storage folder for the rest of the artifacts (transcript.txt,
    /// segments.json, audio.*).
    private var rowActionsMenu: some View {
        Menu {
            if recording.canRetranscribeAsNew {
                Button("Re-transcribe with current model") {
                    appState.retranscribeAsNew(recording)
                }
                .disabled(isRetranscribeDisabled)

                Button("Re-transcribe with cleanup") {
                    appState.retranscribeAsNew(recording, applyCleanup: true)
                }
                .disabled(isRetranscribeDisabled)
            }
            Button("Show metadata") {
                let metadataURL = recording.storageDirectory
                    .appendingPathComponent("metadata.json")
                NSWorkspace.shared.open(metadataURL)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.storageDirectory])
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func formatEditDuration(_ seconds: TimeInterval) -> String {
        let value = seconds.formatted(.number.precision(.fractionLength(1)))
        return "\(value)s"
    }

    private var isReTranscribeDisabled: Bool {
        recording.canRetranscribe == false || appState.recorder.state.isRecording
            || appState.recorder.state == .processing
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
