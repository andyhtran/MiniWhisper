import SwiftUI

private enum ReplacementEditorFocusTarget: Hashable {
    case replacement
    case variant(UUID)
}

private struct ReplacementEditorRoute: Identifiable, Equatable {
    enum Mode: Equatable {
        case add
        case edit(UUID)
    }

    var id: UUID {
        draft.id
    }

    let mode: Mode
    let draft: ReplacementGroupDraft

    var title: String {
        switch mode {
        case .add:
            "Add Replacement"
        case .edit where draft.isRemovalGroup:
            "Remove Phrases"
        case .edit:
            "Edit Replacement"
        }
    }
}

private struct ReplacementGroupDraft: Identifiable, Equatable {
    var id: UUID
    var enabled: Bool
    var replacement: String
    var preserveCase: Bool
    var variants: [ReplacementVariantDraft]

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        replacement: String = "",
        preserveCase: Bool = false,
        variants: [ReplacementVariantDraft] = [ReplacementVariantDraft()]
    ) {
        self.id = id
        self.enabled = enabled
        self.replacement = replacement
        self.preserveCase = preserveCase
        self.variants = variants.isEmpty ? [ReplacementVariantDraft()] : variants
    }

    init(group: ReplacementGroup) {
        self.init(
            id: group.id,
            enabled: group.enabled,
            replacement: group.replacement,
            preserveCase: group.preserveCase,
            variants: group.variants.map(ReplacementVariantDraft.init)
        )
    }

    var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRemovalGroup: Bool {
        trimmedReplacement.isEmpty
    }

    var sanitizedVariants: [ReplacementVariant] {
        variants.compactMap { draft in
            let find = draft.find.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else { return nil }
            return ReplacementVariant(id: draft.id, enabled: draft.enabled, find: find)
        }
    }

    func makeGroup(
        allowEmptyReplacement: Bool = false,
        allowEmptyVariants: Bool = false
    ) -> ReplacementGroup? {
        let variants = sanitizedVariants
        let replacement = allowEmptyReplacement ? "" : trimmedReplacement
        guard allowEmptyReplacement || !replacement.isEmpty else { return nil }
        guard allowEmptyVariants || !variants.isEmpty else { return nil }
        return ReplacementGroup(
            id: id,
            enabled: enabled,
            replacement: replacement,
            preserveCase: allowEmptyReplacement ? false : preserveCase,
            variants: variants
        )
    }
}

private struct ReplacementVariantDraft: Identifiable, Equatable {
    var id: UUID
    var enabled: Bool
    var find: String

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        find: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.find = find
    }

    init(_ variant: ReplacementVariant) {
        self.init(id: variant.id, enabled: variant.enabled, find: variant.find)
    }
}

struct ReplacementsView: View {
    @Binding var settings: ReplacementSettings
    let onSave: () -> Void

    @State private var editorRoute: ReplacementEditorRoute?
    @State private var isDirty = false
    @State private var saveTask: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(400)

    var body: some View {
        Group {
            if let editorRoute {
                ReplacementEditorView(
                    route: editorRoute,
                    existingGroups: settings.groups,
                    onCancel: { self.editorRoute = nil },
                    onSaveGroup: { group in
                        save(group, for: editorRoute.mode)
                    }
                )
            } else {
                listView
            }
        }
        .onChange(of: settings) { _, _ in scheduleSave() }
        .onDisappear {
            editorRoute = nil
            flushSave()
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("Choose the final text once, or use Remove phrases for words that should disappear.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(settings.groups) { group in
                            groupRow(for: group)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 360)
            }

            Button(action: beginAdding) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                    Text("Add Replacement")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
    }

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
                    .transition(.opacity.combined(with: .scale))
            }

            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No replacements yet")
                .font(.system(size: 12, weight: .medium))
            Text("Add a final phrase, then list the ways transcription gets it wrong.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func groupRow(for group: ReplacementGroup) -> some View {
        if let index = settings.groups.firstIndex(where: { $0.id == group.id }) {
            HStack(spacing: 8) {
                Toggle("", isOn: $settings.groups[index].enabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button {
                    beginEditing(group)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(groupTitle(for: group))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .foregroundStyle(.primary)

                            Text(variantSummary(for: group))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Text(variantCountText(for: group))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if !group.isRemovalGroup {
                    Button {
                        settings.groups.removeAll { $0.id == group.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .opacity(group.enabled ? 1 : 0.55)
        }
    }

    private func beginAdding() {
        editorRoute = ReplacementEditorRoute(mode: .add, draft: ReplacementGroupDraft())
    }

    private func beginEditing(_ group: ReplacementGroup) {
        editorRoute = ReplacementEditorRoute(mode: .edit(group.id), draft: ReplacementGroupDraft(group: group))
    }

    private func save(_ group: ReplacementGroup, for mode: ReplacementEditorRoute.Mode) {
        switch mode {
        case .add:
            settings.groups.append(group)
        case let .edit(id):
            if let index = settings.groups.firstIndex(where: { $0.id == id }) {
                settings.groups[index] = group
            } else {
                settings.groups.append(group)
            }
        }
        editorRoute = nil
    }

    private func groupTitle(for group: ReplacementGroup) -> String {
        group.isRemovalGroup ? "Remove phrases" : group.replacement
    }

    private func variantSummary(for group: ReplacementGroup) -> String {
        let finds = group.variants
            .map(\.find)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if finds.isEmpty {
            return group.isRemovalGroup ? "Delete matching text from transcriptions" : "No variants"
        }
        let visible = finds.prefix(3).joined(separator: ", ")
        let hiddenCount = finds.count - min(finds.count, 3)
        return hiddenCount > 0 ? "\(visible), +\(hiddenCount)" : visible
    }

    private func variantCountText(for group: ReplacementGroup) -> String {
        let count = group.variants.count
        if group.isRemovalGroup {
            return count == 1 ? "1 phrase" : "\(count) phrases"
        }
        return count == 1 ? "1 variant" : "\(count) variants"
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

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty {
            onSave()
            isDirty = false
        }
    }
}

private struct ReplacementEditorView: View {
    let route: ReplacementEditorRoute
    let existingGroups: [ReplacementGroup]
    let onCancel: () -> Void
    let onSaveGroup: (ReplacementGroup) -> Void

    @State private var draft: ReplacementGroupDraft
    @FocusState private var focusedField: ReplacementEditorFocusTarget?

    init(
        route: ReplacementEditorRoute,
        existingGroups: [ReplacementGroup],
        onCancel: @escaping () -> Void,
        onSaveGroup: @escaping (ReplacementGroup) -> Void
    ) {
        self.route = route
        self.existingGroups = existingGroups
        self.onCancel = onCancel
        self.onSaveGroup = onSaveGroup
        _draft = State(initialValue: route.draft)
    }

    private var sanitizedVariants: [ReplacementVariant] {
        draft.sanitizedVariants
    }

    private var isRemovalGroup: Bool {
        if case .edit = route.mode {
            return route.draft.isRemovalGroup
        }
        return false
    }

    private var excludingGroupID: UUID? {
        switch route.mode {
        case .add: nil
        case let .edit(id): id
        }
    }

    private var isDuplicateReplacement: Bool {
        let needle = ReplacementSettings.normalized(draft.trimmedReplacement)
        guard !needle.isEmpty else { return false }
        return existingGroups.contains { group in
            if group.id == excludingGroupID { return false }
            return ReplacementSettings.normalized(group.replacement) == needle
        }
    }

    private var hasDuplicateVariantsInDraft: Bool {
        let keys = sanitizedVariants.map { ReplacementSettings.normalized($0.find) }
        return Set(keys).count != keys.count
    }

    private var hasDuplicateVariantInStore: Bool {
        sanitizedVariants.contains { variant in
            let needle = ReplacementSettings.normalized(variant.find)
            return existingGroups.contains { group in
                group.variants.contains { existing in
                    if existing.id == variant.id { return false }
                    return ReplacementSettings.normalized(existing.find) == needle
                }
            }
        }
    }

    private var hasVariantExactlyMatchingReplacement: Bool {
        let replacement = draft.trimmedReplacement
        guard !replacement.isEmpty else { return false }
        return sanitizedVariants.contains { $0.find == replacement }
    }

    private var hasVariantValidationError: Bool {
        hasDuplicateVariantsInDraft || hasDuplicateVariantInStore || hasVariantExactlyMatchingReplacement
    }

    private var canSave: Bool {
        let hasReplacement = isRemovalGroup || !draft.trimmedReplacement.isEmpty
        let hasVariants = isRemovalGroup || !sanitizedVariants.isEmpty
        return hasReplacement
            && hasVariants
            && !isDuplicateReplacement
            && !hasVariantValidationError
    }

    private var replacementFooter: String? {
        isDuplicateReplacement
            ? "A replacement with this text already exists. Open it to add more variants."
            : nil
    }

    private var variantsFooter: String? {
        if hasVariantExactlyMatchingReplacement {
            return "A variant that exactly matches the replacement has no effect."
        }
        if hasDuplicateVariantsInDraft || hasDuplicateVariantInStore {
            return "Each transcript variant can only point to one final text."
        }
        if isRemovalGroup && sanitizedVariants.isEmpty {
            return "Add words or phrases here; matching text will be deleted."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isRemovalGroup {
                        removalIntroSection
                    } else {
                        finalTextSection
                    }
                    variantsSection
                    optionsSection
                }
                .padding(12)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .resignsResponderOnClose()
    }

    private func dismissEditor(then action: @escaping () -> Void) {
        focusedField = nil
        DispatchQueue.main.async { action() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismissEditor(then: onCancel)
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(route.title)
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            Button("Save") {
                guard let group = draft.makeGroup(
                    allowEmptyReplacement: isRemovalGroup,
                    allowEmptyVariants: isRemovalGroup
                ), canSave else { return }
                dismissEditor { onSaveGroup(group) }
            }
            .font(.system(size: 12, weight: .medium))
            .disabled(!canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var removalIntroSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Remove phrases")
            Text("Use this built-in group for words or phrases that should be deleted from transcriptions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finalTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Replace with")

            TextField("Claude Code", text: $draft.replacement)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focusedField, equals: .replacement)
                .onSubmit { focusFirstVariant() }

            if let replacementFooter {
                footerText(replacementFooter, isError: true)
            }
        }
    }

    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(isRemovalGroup ? "Remove when transcription says" : "When transcription says")

            VStack(spacing: 6) {
                ForEach($draft.variants) { $variant in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $variant.enabled)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)

                        TextField(isRemovalGroup ? "um" : "cloud code", text: $variant.find)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focusedField, equals: .variant(variant.id))
                            .onSubmit { addVariant(after: variant.id) }

                        if draft.variants.count > 1 {
                            Button {
                                deleteVariant(id: variant.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete variant")
                        }
                    }
                }
            }

            Button(action: addVariant) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                    Text(isRemovalGroup ? "Add Phrase" : "Add Variant")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if let variantsFooter {
                footerText(variantsFooter, isError: hasVariantValidationError)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Options")

            Toggle(isOn: $draft.enabled) {
                Text("Enabled")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            if !isRemovalGroup {
                Toggle(isOn: $draft.preserveCase) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preserve exact case")
                            .font(.system(size: 12))
                        Text("Apply this final text after capitalization formatting.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func footerText(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func focusFirstVariant() {
        guard let first = draft.variants.first else { return }
        focusedField = .variant(first.id)
    }

    private func addVariant() {
        let newVariant = ReplacementVariantDraft()
        draft.variants.append(newVariant)
        focusedField = .variant(newVariant.id)
    }

    private func addVariant(after id: UUID) {
        guard let index = draft.variants.firstIndex(where: { $0.id == id }) else {
            addVariant()
            return
        }
        let newVariant = ReplacementVariantDraft()
        draft.variants.insert(newVariant, at: index + 1)
        focusedField = .variant(newVariant.id)
    }

    private func deleteVariant(id: UUID) {
        guard draft.variants.count > 1 else { return }
        draft.variants.removeAll { $0.id == id }
    }
}
