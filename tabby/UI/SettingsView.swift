import SwiftUI

/// File overview:
/// Renders Tabby's minimal settings window using the app's existing long-lived services.
/// This view intentionally does not own persistence, runtime bootstrap, or updater lifecycle.
/// It is a read/write surface over those services, while `SettingsCoordinator` owns the window.
///
/// The first pass keeps the surface intentionally small:
/// - app version plus a manual Sparkle update action
/// - current models directory plus open/refresh actions
/// - the currently discovered local model list
struct SettingsView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Updates") {
                    SettingsValueRow(title: "Version") {
                        Text(appVersionText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Check GitHub Releases for a newer version of Tabby.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Spacer(minLength: 0)

                            Button("Check for Updates") {
                                appUpdateManager.checkForUpdates()
                            }
                        }
                    }
                }

                SettingsSection(title: "Models") {
                    SettingsValueRow(title: "Location") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(modelDownloadManager.modelsDirectoryPath)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 8) {
                                Button("Open Folder") {
                                    modelDownloadManager.openModelsDirectory()
                                }

                                Button("Refresh Models") {
                                    refreshModels()
                                }
                            }
                        }
                    }

                    SettingsValueRow(title: "Installed") {
                        installedModelsContent
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 420)
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

    /// The app bundle is the canonical source for human-facing version text.
    /// Keeping this lookup local to the view avoids introducing a settings-specific model object
    /// before the settings surface is large enough to justify one.
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

    @ViewBuilder
    private var installedModelsContent: some View {
        if runtimeModel.availableModels.isEmpty {
            Text("No local GGUF models found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(runtimeModel.availableModels) { model in
                        InstalledModelRow(
                            model: model,
                            isSelected: model.filename == runtimeModel.selectedModelFilename,
                            canDelete: modelDownloadManager.canDeleteModel(filename: model.filename),
                            onDeleteRequested: {
                                pendingDeletionModel = model
                            }
                        )

                        if model.id != runtimeModel.availableModels.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 190, maxHeight: 260, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

/// Shared section container for the settings screen.
/// `GroupBox` gives us native macOS grouping without introducing custom cards or colors.
private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }
}

/// Small labeled row helper for settings content.
/// This keeps alignment consistent across sections without hiding where the real state lives.
private struct SettingsValueRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 84, alignment: .leading)

            content
        }
    }
}

/// Renders one discovered local model in the installed-models list.
/// We show the product-facing alias first and the raw filename second when they differ so the user
/// can recognize both the branded model name and the actual on-disk GGUF file.
private struct InstalledModelRow: View {
    let model: RuntimeModelOption
    let isSelected: Bool
    let canDelete: Bool
    let onDeleteRequested: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)

                if model.displayName != model.filename {
                    Text(model.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if isSelected {
                Text("Selected")
                    .foregroundStyle(.secondary)
            } else if canDelete {
                Button(action: onDeleteRequested) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Delete \(model.displayName)")
            }
        }
        .padding(.vertical, 8)
    }
}
