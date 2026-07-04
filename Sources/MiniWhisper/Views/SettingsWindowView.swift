import AppKit
import Combine
import SwiftUI

enum MiniWhisperSettingsTab: Hashable {
    case general
    case shortcuts
    case integrations
}

private extension MiniWhisperSettingsTab {
    static let contentWidth: CGFloat = 520

    var contentSize: NSSize {
        switch self {
        case .general:
            return NSSize(width: Self.contentWidth, height: 500)
        case .shortcuts:
            return NSSize(width: Self.contentWidth, height: 390)
        case .integrations:
            return NSSize(width: Self.contentWidth, height: 500)
        }
    }
}

@MainActor
final class MiniWhisperSettingsNavigation: ObservableObject {
    static let shared = MiniWhisperSettingsNavigation()
    @Published var selectedTab: MiniWhisperSettingsTab = .general
    private init() {}
}

struct MiniWhisperSettingsView: View {
    @ObservedObject private var nav = MiniWhisperSettingsNavigation.shared

    var body: some View {
        Group {
            switch nav.selectedTab {
            case .general:
                GeneralSettingsPage()
            case .shortcuts:
                ShortcutSettingsPage()
            case .integrations:
                IntegrationSettingsPage()
            }
        }
        .frame(
            width: nav.selectedTab.contentSize.width,
            height: nav.selectedTab.contentSize.height,
            alignment: .top
        )
    }
}

@MainActor
final class MiniWhisperSettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = MiniWhisperSettingsWindowController()

    private let nav = MiniWhisperSettingsNavigation.shared
    private var navObserver: AnyCancellable?

    private struct TabSpec {
        let tab: MiniWhisperSettingsTab
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
    }

    private static let specs: [TabSpec] = [
        TabSpec(tab: .general, id: .init("general"), label: "General", symbol: "gearshape"),
        TabSpec(tab: .shortcuts, id: .init("shortcuts"), label: "Shortcuts", symbol: "keyboard"),
        TabSpec(tab: .integrations, id: .init("integrations"), label: "Integrations", symbol: "terminal"),
    ]

    private static func spec(for tab: MiniWhisperSettingsTab) -> TabSpec? {
        specs.first { $0.tab == tab }
    }

    private static func spec(for id: NSToolbarItem.Identifier) -> TabSpec? {
        specs.first { $0.id == id }
    }

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func open(appState: AppState, updaterController: UpdaterProviding?) {
        if window == nil {
            configureWindow(appState: appState, updaterController: updaterController)
        }

        resizeWindow(for: nav.selectedTab, animate: false)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(appState: AppState, updaterController: UpdaterProviding?) {
        let rootView = MiniWhisperSettingsView()
            .environment(appState)
            .environment(\.updaterController, updaterController)
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        window.title = "MiniWhisper Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MiniWhisperSettingsWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "MiniWhisperSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Self.spec(for: nav.selectedTab)?.id

        window.toolbar = toolbar
        window.toolbarStyle = .preference
        self.window = window

        navObserver = nav.$selectedTab.sink { [weak self, weak toolbar] tab in
            let newID = Self.spec(for: tab)?.id
            if toolbar?.selectedItemIdentifier != newID {
                toolbar?.selectedItemIdentifier = newID
            }
            self?.resizeWindow(for: tab, animate: true)
        }
    }

    private func resizeWindow(for tab: MiniWhisperSettingsTab, animate: Bool) {
        guard let window else { return }

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let targetContentRect = NSRect(origin: contentRect.origin, size: tab.contentSize)
        var targetFrame = window.frameRect(forContentRect: targetContentRect)
        targetFrame.origin.x = window.frame.midX - targetFrame.width / 2
        targetFrame.origin.y = window.frame.maxY - targetFrame.height

        if animate, window.isVisible {
            window.animator().setFrame(targetFrame, display: true)
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let spec = Self.spec(for: id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.action = #selector(selectTab(_:))
        item.label = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        if let spec = Self.spec(for: sender.itemIdentifier) {
            nav.selectedTab = spec.tab
        }
    }
}

private struct GeneralSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.updaterController) private var updaterController
    @StateObject private var launchManager = LaunchAtLoginManager.shared
    @State private var autoUpdateEnabled = true
    @State private var vadEnabled = VADSettings.enabled
    @State private var editModeBehavior = EditModeSettings.behavior

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Behavior") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchManager.isEnabled },
                        set: { launchManager.isEnabled = $0 }
                    )
                )

                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { autoUpdateEnabled },
                        set: {
                            autoUpdateEnabled = $0
                            updaterController?.automaticallyChecksForUpdates = $0
                        }
                    )
                )

                LabeledContent("Check for updates") {
                    updateCheckContent
                }
            }

            Section("Transcription") {
                Toggle(
                    "Trim long silences",
                    isOn: Binding(
                        get: { vadEnabled },
                        set: {
                            vadEnabled = $0
                            VADSettings.enabled = $0
                        }
                    )
                )

                Toggle(isOn: $appState.replacementSettings.enabled) {
                    InfoLabel(
                        title: "Enable replacements",
                        text: "Apply find-and-replace rules to every transcription."
                    )
                }
            }

            Section("AI Editing") {
                Picker(
                    selection: Binding(
                        get: { editModeBehavior },
                        set: {
                            editModeBehavior = $0
                            EditModeSettings.behavior = $0
                            appState.editModeBehavior = $0
                        }
                    )
                ) {
                    ForEach(EditModeBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.settingsDisplayName).tag(behavior)
                    }
                } label: {
                    InfoLabel(
                        title: "Enabled features",
                        text: "Recording cleanup polishes dictated text before paste. Selected text editing rewrites highlighted text."
                    )
                }

                if editModeBehavior.selectionEnabled {
                    Picker(
                        selection: Binding(
                            get: { appState.voiceEditEnabled },
                            set: {
                                appState.voiceEditEnabled = $0
                                EditModeSettings.voiceEdit = $0
                            }
                        )
                    ) {
                        Text("Clean automatically").tag(false)
                        Text("Dictate instruction").tag(true)
                    } label: {
                        InfoLabel(
                            title: "Selected text action",
                            text: "Clean automatically rewrites selected text immediately. Dictate instruction lets you speak how to change it."
                        )
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppVersionInfo.current.displayString)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onChange(of: appState.replacementSettings) {
            appState.replacementSettings.save()
        }
        .onAppear {
            launchManager.refresh()
            autoUpdateEnabled = updaterController?.automaticallyChecksForUpdates ?? true
            vadEnabled = VADSettings.enabled
            editModeBehavior = EditModeSettings.behavior
        }
    }

    /// Mirrors the live update state next to the Check Now button, since the
    /// menu popover (where the full banner lives) is closed while the user
    /// is in this window.
    @ViewBuilder private var updateCheckContent: some View {
        switch updaterController?.updateViewModel.state ?? .idle {
        case .idle:
            checkNowButton

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }

        case .updateAvailable(let update):
            Button("Install \(update.version)") {
                update.install()
            }

        case .downloading(let download):
            Text(
                download.fraction.map { "Downloading… \(Int($0 * 100))%" }
                    ?? "Downloading…"
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()

        case .extracting:
            Text("Preparing…")
                .foregroundStyle(.secondary)

        case .installing:
            Text("Installing… MiniWhisper will relaunch")
                .foregroundStyle(.secondary)

        case .notFound:
            Text("You're up to date")
                .foregroundStyle(.secondary)

        case .failed:
            HStack(spacing: 8) {
                Text("Update failed")
                    .foregroundStyle(.secondary)
                checkNowButton
            }
        }
    }

    private var checkNowButton: some View {
        Button("Check Now") {
            guard updaterController?.updateViewModel.state.allowsManualCheck == true else {
                return
            }
            updaterController?.checkForUpdates(nil)
        }
        .disabled(updateCheckDisabled)
    }

    private var updateCheckDisabled: Bool {
        guard let updaterController, updaterController.isAvailable else {
            return true
        }
        return !updaterController.updateViewModel.state.allowsManualCheck
    }
}

private struct ShortcutSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(CustomShortcutName.allCases, id: \.self) { name in
                    SettingsShortcutRow(name: name)
                }
            }

            Section("Defaults") {
                Button("Reset Shortcuts") {
                    CustomShortcutStorage.saveAll(CustomShortcutStorage.defaultShortcuts())
                    appState.reloadShortcuts()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}

private struct SettingsShortcutRow: View {
    @Environment(AppState.self) private var appState
    let name: CustomShortcutName
    @State private var isEditing = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.settingsTitle)
                Text(name.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isEditing {
                ShortcutRecorderView(
                    shortcut: Binding(
                        get: { CustomShortcutStorage.get(name) },
                        set: { newShortcut in
                            CustomShortcutStorage.set(newShortcut, for: name)
                            appState.reloadShortcuts()
                            isEditing = false
                        }
                    )
                )
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.borderless)
            } else {
                Button(shortcutLabel) { isEditing = true }
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var shortcutLabel: String {
        CustomShortcutStorage.get(name)?.compactDisplayString ?? "Not Set"
    }
}

private struct IntegrationSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Command Line") {
                CLIInstallSettingsRow()
            }

            Section("Agent Skills") {
                Toggle("Enable replacements", isOn: $appState.replacementSettings.enabled)
                ClaudeSkillSettingsRow()
                    .disabled(!appState.replacementSettings.enabled)
            }

            Section("Files") {
                Button("Open MiniWhisper Folder") {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: Recording.baseDirectory.deletingLastPathComponent().path
                    )
                }

                if !appState.editModeBehavior.isOff {
                    CleanupPromptSettingsRow()
                }

                Button("Open Menu Bar Settings") {
                    SystemSettingsLinks.openMenuBarSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onChange(of: appState.replacementSettings) {
            appState.replacementSettings.save()
        }
    }
}

private struct CLIInstallSettingsRow: View {
    @Environment(AppState.self) private var appState
    private let manager = CLIInstallManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MiniWhisper CLI")
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(primaryButtonTitle, action: primaryAction)
                .disabled(primaryButtonDisabled)
        }
        .onAppear { manager.refresh() }

        if manager.hasConflict || manager.isInstalled || manager.isBroken {
            HStack {
                Text(manager.managedInstallPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Reveal") { manager.revealInstallLocation() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var statusText: String {
        if !manager.bundledCLIAvailable {
            return "CLI binary missing from this app build"
        }
        if manager.hasConflict {
            return "A different miniwhispercli already exists at \(manager.displayInstallPath)"
        }
        if manager.isBroken {
            return "Install is broken; repair the managed copy"
        }
        if manager.needsUpdate {
            return "Update available at \(manager.displayInstallPath)"
        }
        if manager.isInstalled {
            return "Installed at \(manager.displayInstallPath)"
        }
        return "Install to \(manager.displayInstallPath)"
    }

    private var statusColor: Color {
        if manager.hasConflict || manager.isBroken { return .orange }
        if manager.needsUpdate || manager.isInstalled { return .accentColor }
        return .secondary
    }

    private var primaryButtonTitle: String {
        if manager.hasConflict { return "Blocked" }
        if !manager.bundledCLIAvailable { return "Unavailable" }
        if manager.isBroken { return "Repair" }
        if manager.needsUpdate { return "Update" }
        if manager.isInstalled { return "Uninstall" }
        return "Install"
    }

    private var primaryButtonDisabled: Bool {
        manager.hasConflict || !manager.bundledCLIAvailable
    }

    private func primaryAction() {
        if manager.isInstalled, !manager.needsUpdate, !manager.isBroken {
            uninstall()
        } else {
            installOrUpdate()
        }
    }

    private func installOrUpdate() {
        do {
            try manager.installOrUpdate()
            appState.toast.showInfo(
                title: "CLI Installed",
                message: "\(manager.displayInstallPath) is ready."
            )
        } catch {
            appState.toast.showError(
                title: "Couldn't Install CLI",
                message: error.localizedDescription
            )
            manager.refresh()
        }
    }

    private func uninstall() {
        do {
            try manager.uninstall()
            appState.toast.showInfo(title: "CLI Uninstalled")
        } catch {
            appState.toast.showError(
                title: "Couldn't Uninstall CLI",
                message: error.localizedDescription
            )
            manager.refresh()
        }
    }
}

private struct ClaudeSkillSettingsRow: View {
    @Environment(AppState.self) private var appState
    private let manager = ClaudeSkillManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code replacement skill")
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { toggle($0) }
                )
            )
            .labelsHidden()
            .disabled(!manager.claudeCodeInstalled || manager.hasConflict)
        }
        .onAppear { manager.refresh() }

        if manager.hasConflict {
            HStack {
                Spacer()
                Button("Reveal Conflict") { manager.revealConflictInFinder() }
                    .buttonStyle(.borderless)
            }
        } else if manager.claudeCodeInstalled, let updateButtonLabel {
            HStack {
                Spacer()
                Button(updateButtonLabel, action: applyUpdate)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var statusText: String {
        if !manager.claudeCodeInstalled {
            return "Claude Code not detected"
        }
        if manager.hasConflict {
            return "Another skill with this name already exists"
        }
        if let syncText {
            return syncText
        }
        return "Allow Claude to add replacement rules"
    }

    private var statusColor: Color {
        if manager.hasConflict { return .orange }
        if !manager.claudeCodeInstalled { return .secondary }
        return .accentColor
    }

    private var syncText: String? {
        switch manager.syncStatus {
        case .upToDate: return nil
        case .updateAvailable: return "Update available"
        case .modified: return "Modified"
        case .modifiedAndUpdateAvailable: return "Modified; update available"
        }
    }

    private var updateButtonLabel: String? {
        switch manager.syncStatus {
        case .upToDate: return nil
        case .updateAvailable: return "Update"
        case .modified: return "Reset to default"
        case .modifiedAndUpdateAvailable: return "Update and overwrite edits"
        }
    }

    private func toggle(_ on: Bool) {
        do {
            try on ? manager.enable() : manager.disable()
        } catch {
            appState.toast.showError(
                title: on ? "Couldn't Enable Skill" : "Couldn't Disable Skill",
                message: error.localizedDescription
            )
            manager.refresh()
        }
    }

    private func applyUpdate() {
        do {
            try manager.applyBundledVersion()
        } catch {
            appState.toast.showError(
                title: "Update Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct CleanupPromptSettingsRow: View {
    @Environment(AppState.self) private var appState
    @State private var hasCustomPrompt = CleanupPromptStore.hasCustomPrompt

    var body: some View {
        HStack {
            Button("Edit cleanup prompt", action: edit)

            Spacer()

            if hasCustomPrompt {
                Button("Reset", action: confirmReset)
                    .foregroundStyle(Color.red)
            }
        }
        .onAppear { hasCustomPrompt = CleanupPromptStore.hasCustomPrompt }
    }

    private func edit() {
        do {
            try CleanupPromptStore.seedIfMissing()
            NSWorkspace.shared.open(CleanupPromptStore.fileURL)
            hasCustomPrompt = CleanupPromptStore.hasCustomPrompt
        } catch {
            appState.toast.showError(
                title: "Couldn't Open Prompt File",
                message: error.localizedDescription
            )
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset cleanup prompt?"
        alert.informativeText =
            "This overwrites your edits to cleanup-prompt.md with the bundled default. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try CleanupPromptStore.resetToDefault()
            hasCustomPrompt = false
        } catch {
            appState.toast.showError(
                title: "Reset Failed",
                message: error.localizedDescription
            )
        }
    }
}

private extension EditModeBehavior {
    var settingsDisplayName: String {
        switch self {
        case .off: return "Off"
        case .both: return "Both"
        case .autoCleanup: return "Cleanup"
        case .selection: return "Selection"
        }
    }
}

private extension CustomShortcutName {
    var settingsTitle: String {
        switch self {
        case .toggleRecording: return "Toggle Recording"
        case .cancelRecording: return "Cancel Recording"
        case .autoCleanupRecording: return "Cleanup Recording"
        case .editSelection: return "Edit Selection"
        }
    }

    var settingsDescription: String {
        switch self {
        case .toggleRecording: return "Start or stop normal transcription"
        case .cancelRecording: return "Cancel the active recording"
        case .autoCleanupRecording: return "Record and run AI cleanup before paste"
        case .editSelection: return "Edit selected text with AI"
        }
    }
}
