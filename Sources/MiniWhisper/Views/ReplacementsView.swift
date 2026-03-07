import SwiftUI

struct ReplacementsView: View {
    @Binding var settings: ReplacementSettings
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Replacements")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: settings.enabled) { onSave() }
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
                                onSave()
                            })
                        }
                    }
                }

                Button {
                    settings.rules.append(ReplacementRule())
                    onSave()
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
        .onDisappear { onSave() }
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
