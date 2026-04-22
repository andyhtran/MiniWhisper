import SwiftUI

fileprivate enum ReplacementsFocusTarget: Hashable {
    case find(UUID)
    case replace(UUID)
}

struct ReplacementsView: View {
    @Binding var settings: ReplacementSettings
    let onSave: () -> Void

    @State private var isEditing = false
    @State private var draftRules: [ReplacementRule] = []
    @State private var isDirty = false
    @State private var saveTask: Task<Void, Never>?

    @FocusState private var focusedField: ReplacementsFocusTarget?

    // Short enough to feel instant after a checkbox flip, long enough to
    // coalesce a burst of rapid toggles into a single disk write.
    private static let debounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("Auto-replace text after transcription")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if !visibleRules.isEmpty {
                VStack(spacing: 6) {
                    ForEach(visibleRules) { rule in
                        ruleRow(for: rule)
                    }
                }
            }

            Button(action: addRule) {
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
        .padding(12)
        .frame(width: 300)
        // Checkbox toggles in view mode mutate settings directly → debounced save.
        // Save button in edit mode also mutates settings → same path fires.
        // Cancel never touches settings, so no save happens.
        .onChange(of: settings) { _, _ in scheduleSave() }
        .onDisappear { handleClose() }
    }

    // MARK: - Header

    private var header: some View {
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

    // MARK: - Rule Row

    // During edit mode rows render drafts; in view mode they render committed
    // settings so checkbox toggles can flow back without an explicit save.
    private var visibleRules: [ReplacementRule] {
        isEditing ? draftRules : settings.rules
    }

    @ViewBuilder
    private func ruleRow(for rule: ReplacementRule) -> some View {
        if isEditing {
            if let index = draftRules.firstIndex(where: { $0.id == rule.id }) {
                EditableRuleRow(
                    rule: $draftRules[index],
                    focusedField: $focusedField,
                    onDelete: { draftRules.removeAll { $0.id == rule.id } }
                )
            }
        } else {
            if let index = settings.rules.firstIndex(where: { $0.id == rule.id }) {
                ReadOnlyRuleRow(
                    rule: $settings.rules[index],
                    onDelete: { settings.rules.removeAll { $0.id == rule.id } }
                )
            }
        }
    }

    // MARK: - Actions

    private func beginEditing() {
        draftRules = settings.rules
        isEditing = true
    }

    private func confirm() {
        settings.rules = draftRules
        focusedField = nil
        isEditing = false
    }

    private func cancel() {
        draftRules = []
        focusedField = nil
        isEditing = false
    }

    private func addRule() {
        // Entering edit mode just to add a new rule keeps all mutations in
        // draft-land until the user confirms. Matches the Settings popover's
        // modal-edit model.
        if !isEditing {
            draftRules = settings.rules
            isEditing = true
        }
        let newRule = ReplacementRule()
        draftRules.append(newRule)
        DispatchQueue.main.async {
            focusedField = .find(newRule.id)
        }
    }

    // Close = auto-save (user's preference for v1). Commits any in-flight
    // drafts, then flushes the debounced save immediately.
    private func handleClose() {
        if isEditing {
            settings.rules = draftRules
            isEditing = false
        }
        flushSave()
    }

    // MARK: - Debounced save

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

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty {
            onSave()
            isDirty = false
        }
    }
}

// MARK: - Row variants

private struct ReadOnlyRuleRow: View {
    @Binding var rule: ReplacementRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            ReadOnlyCell(text: rule.find, placeholder: "—")
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            ReadOnlyCell(text: rule.replace, placeholder: "—")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct EditableRuleRow: View {
    @Binding var rule: ReplacementRule
    @FocusState.Binding var focusedField: ReplacementsFocusTarget?
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
                .focused($focusedField, equals: .find(rule.id))

            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            TextField("Replace", text: $rule.replace)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(minWidth: 80)
                .focused($focusedField, equals: .replace(rule.id))

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ReadOnlyCell: View {
    let text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                } else {
                    Text(text).textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
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
