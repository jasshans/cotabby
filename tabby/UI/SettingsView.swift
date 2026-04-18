import SwiftUI

/// File overview:
/// Renders Tabby's settings window as the canonical home for durable user preferences.
///
/// Why this file exists:
/// the menu bar panel is a quick-control surface, but durable settings should also exist in a
/// stable window the user can revisit later. This view intentionally does not own persistence or
/// side effects; it reads and mutates long-lived services created by the app environment.
struct SettingsView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var launchAtLoginService: LaunchAtLoginService
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    let onShowWelcome: () -> Void

    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        Form {
            settingsHeader
            generalSection
            autocompleteSection
            guidedModeSection
            permissionsSection
            localModelsSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            refreshAppleIntelligenceAvailabilityIfNeeded()
            launchAtLoginService.refresh()
            permissionManager.refresh()
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, _ in
            pendingDeletionModel = nil
            refreshAppleIntelligenceAvailabilityIfNeeded()
        }
        .alert(
            "Delete Model?",
            isPresented: pendingDeletionAlertBinding,
            presenting: pendingDeletionModel
        ) { model in
            Button("Delete") {
                deleteModel(model)
            }

            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Remove \(model.displayName) from Tabby's local models folder?")
        }
    }

    @ViewBuilder
    private var settingsHeader: some View {
        Section {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))

                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Tabby")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                    Text("Local AI Autocomplete")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            Toggle("Open at Login", isOn: launchAtLoginBinding)
                .disabled(!launchAtLoginService.state.canToggle)

            if let message = launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(launchAtLoginMessageColor)
            }

            LabeledContent("Onboarding") {
                Button("Open Welcome Guide") {
                    onShowWelcome()
                }
            }
        }
    }

    @ViewBuilder
    private var autocompleteSection: some View {
        Section("Autocomplete") {
            Toggle("Enabled", isOn: globallyEnabledBinding)

            Toggle("Caret Indicator", isOn: showCaretIndicatorBinding)

            Picker("Engine", selection: selectedEngineBinding) {
                ForEach(SuggestionEngineKind.allCases) { engine in
                    Text(engine.displayLabel)
                        .tag(engine)
                }
            }

            if suggestionSettings.selectedEngine == .appleIntelligence {
                LabeledContent("Availability") {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Runtime") {
                    Text(runtimeModel.state.summary)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Length", selection: selectedWordCountPresetBinding) {
                ForEach(SuggestionWordCountPreset.allCases) { preset in
                    Text(preset.displayLabel)
                        .tag(preset)
                }
            }

            Picker("Local Prompt", selection: selectedLocalPromptModeBinding) {
                ForEach(SuggestionPromptMode.allCases) { mode in
                    Text(mode.displayLabel)
                        .tag(mode)
                }
            }

            if suggestionSettings.selectedEngine != .llamaOpenSource {
                Text("Local Prompt is saved for the Open Source engine and does not affect Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var guidedModeSection: some View {
        Section("Guided Mode") {
            VStack(alignment: .leading, spacing: 8) {
                Text(guidedModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: customAIInstructionsBinding)
                    .font(.system(size: 13))
                    .frame(minHeight: 120)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Section("Permissions") {
            Text("Tabby needs Accessibility and Input Monitoring for autocomplete.")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsPermissionRow(
                title: "Accessibility",
                granted: permissionManager.accessibilityGranted,
                action: permissionManager.openAccessibilitySettings
            )

            settingsPermissionRow(
                title: "Input Monitoring",
                granted: permissionManager.inputMonitoringGranted,
                action: permissionManager.openInputMonitoringSettings
            )
        }
    }

    @ViewBuilder
    private var localModelsSection: some View {
        Section("Local Models") {
            if suggestionSettings.selectedEngine != .llamaOpenSource {
                Text("These models are used when Engine is set to Llama Open Source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if runtimeModel.availableModels.isEmpty {
                Text("No local GGUF models found. Install one below or add your own model file.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Selected Model", selection: selectedModelBinding) {
                    ForEach(runtimeModel.availableModels) { model in
                        Text(model.displayName)
                            .tag(model.filename)
                    }
                }
            }

            DownloadableModelCatalogView(
                modelDownloadManager: modelDownloadManager,
                onRefreshModels: refreshModels
            )

            LabeledContent("Folder") {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(modelDownloadManager.modelsDirectoryPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)

                    HStack(spacing: 8) {
                        Button("Open Folder") {
                            modelDownloadManager.openModelsDirectory()
                        }

                        Button("Refresh") {
                            refreshModels()
                        }
                    }
                }
            }

            if !runtimeModel.availableModels.isEmpty {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(runtimeModel.availableModels) { model in
                    installedModelRow(model)
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: appVersionText)

            LabeledContent {
                Button("Check for Updates") {
                    appUpdateManager.checkForUpdates()
                }
            } label: {
                Text("Check GitHub Releases for updates.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func installedModelRow(_ model: RuntimeModelOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)

                if model.displayName != model.filename {
                    Text(model.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if model.filename == runtimeModel.selectedModelFilename {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if modelDownloadManager.canDeleteModel(filename: model.filename) {
                Button {
                    pendingDeletionModel = model
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete \(model.displayName)")
            }
        }
    }

    @ViewBuilder
    private func settingsPermissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)

            Spacer(minLength: 0)

            Text(granted ? "Granted" : "Needs Access")
                .font(.caption.weight(.medium))
                .foregroundStyle(granted ? .green : .orange)

            if !granted {
                Button("Open Settings") {
                    action()
                }
                .controlSize(.small)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginService.state.isEnabled },
            set: { enabled in
                launchAtLoginService.setEnabled(enabled)
            }
        )
    }

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isGloballyEnabled },
            set: { suggestionSettings.setGloballyEnabled($0) }
        )
    }

    private var showCaretIndicatorBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showCaretIndicator },
            set: { suggestionSettings.setShowCaretIndicator($0) }
        )
    }

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { engine in
                suggestionSettings.selectEngine(engine)
            }
        )
    }

    private var selectedWordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionSettings.selectedWordCountPreset },
            set: { preset in
                suggestionSettings.selectWordCountPreset(preset)
            }
        )
    }

    private var selectedLocalPromptModeBinding: Binding<SuggestionPromptMode> {
        Binding(
            get: { suggestionSettings.selectedLocalPromptMode },
            set: { mode in
                suggestionSettings.selectLocalPromptMode(mode)
            }
        )
    }

    private var customAIInstructionsBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.customAIInstructions },
            set: { instructions in
                suggestionSettings.setCustomAIInstructions(instructions)
            }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                Task {
                    await runtimeModel.selectModel(filename)
                }
            }
        )
    }

    private var guidedModeDescription: String {
        if suggestionSettings.selectedEngine == .llamaOpenSource,
           suggestionSettings.selectedLocalPromptMode == .guided
        {
            return "These instructions are active right now for Guided mode on the Open Source engine."
        }

        if suggestionSettings.selectedEngine == .llamaOpenSource {
            return "These instructions are saved for Guided mode. Prefix Only ignores this field."
        }

        return "These instructions are saved for Guided mode on the Open Source engine."
    }

    private var launchAtLoginMessage: String? {
        if let lastErrorMessage = launchAtLoginService.lastErrorMessage {
            return lastErrorMessage
        }

        return launchAtLoginService.state.detail
    }

    private var launchAtLoginMessageColor: Color {
        if launchAtLoginService.lastErrorMessage != nil {
            return .red
        }

        if case .requiresApproval = launchAtLoginService.state {
            return .orange
        }

        return .secondary
    }

    /// The app bundle is the canonical source for human-facing version text.
    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?):
            return buildNumber
        default:
            return "Unknown"
        }
    }

    /// SwiftUI's alert API wants a Boolean binding, while the view naturally tracks the model the
    /// user intends to delete. This adapter keeps the real source of truth expressive and still
    /// allows the standard confirmation alert API to drive presentation.
    private var pendingDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionModel != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionModel = nil
                }
            }
        )
    }

    private func deleteModel(_ model: RuntimeModelOption) {
        modelDownloadManager.deleteModel(filename: model.filename)
        runtimeModel.refreshAvailableModels()
        pendingDeletionModel = nil
    }

    private func refreshModels() {
        modelDownloadManager.refreshModelStates()
        runtimeModel.refreshAvailableModels()
    }

    private func refreshAppleIntelligenceAvailabilityIfNeeded() {
        guard suggestionSettings.selectedEngine == .appleIntelligence else {
            return
        }

        foundationModelAvailabilityService.refresh()
    }
}
