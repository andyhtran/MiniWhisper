import SwiftUI

struct ReplacementsView: View {
    @Binding var settings: ReplacementSettings
    let onSave: () -> Void

    // Any mutation of `settings` (toggle, checkbox, text edit, add, delete) flips
    // this on and starts the debounce timer. Cleared when the write lands.
    @State private var isDirty = false
    @State private var saveTask: Task<Void, Never>?

    // Short enough to feel instant after you stop typing, long enough to
    // coalesce a burst of keystrokes into a single write.
    private static let debounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Replacements")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                        .transition(.opacity.combined(with: .scale))
                }

                Spacer()

                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.enabled {
                Text("Auto-replace text after transcription")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if !settings.rules.isEmpty {
                    VStack(spacing: 6) {
                        ForEach($settings.rules) { $rule in
                            ReplacementRuleRow(rule: $rule, onDelete: {
                                settings.rules.removeAll { $0.id == rule.id }
                            })
                        }
                    }
                }

                Button {
                    settings.rules.append(ReplacementRule())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("Add Rule")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
        // One hook covers every mutation path since ReplacementSettings is Equatable.
        .onChange(of: settings) { _, _ in scheduleSave() }
        .onDisappear { flushSave() }
    }

    private func scheduleSave() {
        withAnimation(.easeInOut(duration: 0.15)) { isDirty = true }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            onSave()
            withAnimation(.easeInOut(duration: 0.15)) { isDirty = false }
        }
    }

    // Popover closing is our hard commit boundary — don't wait out the debounce.
    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty {
            onSave()
            isDirty = false
        }
    }
}

private struct ReplacementRuleRow: View {
    @Binding var rule: ReplacementRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            TextField("Find", text: $rule.find)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(minWidth: 80)

            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            TextField("Replace", text: $rule.replace)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(minWidth: 80)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
