import AppKit
import Combine
import Foundation

/// File overview:
/// Performs Tabby's self-uninstall flow after the user explicitly confirms it.
///
/// Why this type exists:
/// uninstalling combines multiple side effects: stopping local runtime work, unregistering the
/// login item, deleting user-scoped data, moving the app bundle to Trash, and terminating the app.
/// Keeping that orchestration in `Services/` prevents the Settings UI from owning destructive
/// filesystem behavior.
@MainActor
final class AppUninstallService: ObservableObject {
    @Published private(set) var isUninstalling = false
    @Published private(set) var lastErrorMessage: String?

    private let launchAtLoginService: LaunchAtLoginService
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let bundle: Bundle
    private let userDefaults: UserDefaults
    private let terminateApplication: @MainActor () -> Void

    init(
        launchAtLoginService: LaunchAtLoginService,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.launchAtLoginService = launchAtLoginService
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.fileManager = fileManager
        self.workspace = workspace
        self.bundle = bundle
        self.userDefaults = userDefaults
        self.terminateApplication = terminateApplication
    }

    func uninstall() async {
        guard !isUninstalling else {
            return
        }

        isUninstalling = true
        defer {
            isUninstalling = false
        }

        do {
            try await performUninstall()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func performUninstall() async throws {
        let cleanupPlan = try AppUninstallCleanupPlan.make(
            bundle: bundle,
            fileManager: fileManager
        )
        try validateAppBundle(cleanupPlan.appBundleURL)

        // Stop work that may have open file handles before removing the model directory.
        modelDownloadManager.cancelAllDownloads()
        await runtimeModel.stopAndWait()
        try unregisterLoginItemIfNeeded()

        userDefaults.removePersistentDomain(forName: cleanupPlan.userDefaultsDomain)
        _ = userDefaults.synchronize()

        try removeData(at: removableDataURLs(for: cleanupPlan))
        try await moveAppBundleToTrash(cleanupPlan.appBundleURL)
        terminateApplication()
    }

    private func unregisterLoginItemIfNeeded() throws {
        launchAtLoginService.refresh()

        guard launchAtLoginService.state.isEnabled else {
            return
        }

        launchAtLoginService.setEnabled(false)
        launchAtLoginService.refresh()

        if launchAtLoginService.state.isEnabled {
            throw AppUninstallServiceError.loginItemRemovalFailed(
                launchAtLoginService.lastErrorMessage
                    ?? "macOS did not unregister Tabby from Open at Login."
            )
        }
    }

    private func removeData(at urls: [URL]) throws {
        var failures: [AppUninstallRemovalFailure] = []

        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }

            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append(
                    AppUninstallRemovalFailure(
                        path: url.path,
                        message: error.localizedDescription
                    )
                )
            }
        }

        guard failures.isEmpty else {
            throw AppUninstallServiceError.dataRemovalFailed(failures)
        }
    }

    private func removableDataURLs(for cleanupPlan: AppUninstallCleanupPlan) throws -> [URL] {
        let byHostPreferenceURLs = try byHostPreferenceURLs(for: cleanupPlan)
        return cleanupPlan.removableDataURLs + byHostPreferenceURLs
    }

    private func byHostPreferenceURLs(for cleanupPlan: AppUninstallCleanupPlan) throws -> [URL] {
        var isDirectory = ObjCBool(false)
        let directoryExists = fileManager.fileExists(
            atPath: cleanupPlan.byHostPreferencesDirectoryURL.path,
            isDirectory: &isDirectory
        )

        guard directoryExists, isDirectory.boolValue else {
            return []
        }

        do {
            return try fileManager
                .contentsOfDirectory(
                    at: cleanupPlan.byHostPreferencesDirectoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .filter { url in
                    url.lastPathComponent.hasPrefix(cleanupPlan.byHostPreferencesFilenamePrefix)
                        && url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame
                }
        } catch {
            throw AppUninstallServiceError.byHostPreferenceDiscoveryFailed(
                cleanupPlan.byHostPreferencesDirectoryURL.path,
                error.localizedDescription
            )
        }
    }

    private func validateAppBundle(_ appBundleURL: URL) throws {
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: appBundleURL.path, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue,
              appBundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        else {
            throw AppUninstallServiceError.appBundleUnavailable(appBundleURL.path)
        }
    }

    private func moveAppBundleToTrash(_ appBundleURL: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            workspace.recycle([appBundleURL]) { _, error in
                if let error {
                    continuation.resume(
                        throwing: AppUninstallServiceError.trashFailed(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

struct AppUninstallRemovalFailure {
    let path: String
    let message: String
}

enum AppUninstallServiceError: LocalizedError {
    case appBundleUnavailable(String)
    case byHostPreferenceDiscoveryFailed(String, String)
    case dataRemovalFailed([AppUninstallRemovalFailure])
    case loginItemRemovalFailed(String)
    case trashFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleUnavailable(let path):
            return "Tabby could not uninstall because \(path) is not a movable app bundle."
        case .byHostPreferenceDiscoveryFailed(let path, let message):
            return "Tabby could not inspect per-host preferences at \(path): \(message)"
        case .dataRemovalFailed(let failures):
            let paths = failures
                .prefix(3)
                .map { "\($0.path): \($0.message)" }
                .joined(separator: "\n")
            return "Tabby could not remove all local data:\n\(paths)"
        case .loginItemRemovalFailed(let message):
            return "Tabby could not remove itself from Open at Login: \(message)"
        case .trashFailed(let message):
            return "Tabby could not move itself to the Trash: \(message)"
        }
    }
}
