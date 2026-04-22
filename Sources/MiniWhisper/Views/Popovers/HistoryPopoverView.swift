import SwiftUI

// MARK: - History Popover

struct HistoryPopoverView: View {
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
