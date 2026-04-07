import SwiftUI

struct ModelPickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcription Model")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 10)

            VStack(spacing: 2) {
                ModelRow(
                    icon: "bolt.fill",
                    title: "English Only",
                    subtitle: "Fast · English",
                    badge: nil,
                    isSelected: appState.transcriptionMode == .english
                ) {
                    appState.switchTranscriptionMode(to: .english)
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
        }
        .padding(12)
        .frame(width: 260)
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
