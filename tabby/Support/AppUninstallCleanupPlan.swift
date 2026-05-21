import Foundation

/// File overview:
/// Describes which user-scoped files Tabby should remove during uninstall.
///
/// Why this file exists:
/// computing filesystem locations is deterministic, so it belongs in `Support/` instead of the
/// side-effectful uninstall service. Keeping this as a pure value lets tests verify the cleanup
/// surface without moving files, touching preferences, or trashing the app bundle.
struct AppUninstallCleanupPlan: Equatable {
    let bundleIdentifier: String
    let appBundleURL: URL
    let removableDataURLs: [URL]
    let byHostPreferencesDirectoryURL: URL
    let byHostPreferencesFilenamePrefix: String

    var userDefaultsDomain: String {
        bundleIdentifier
    }

    static func make(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> AppUninstallCleanupPlan {
        let libraryDirectoryURL =
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)

        return try make(
            bundleIdentifier: bundle.bundleIdentifier,
            appBundleURL: bundle.bundleURL,
            appNameCandidates: appNameCandidates(from: bundle),
            libraryDirectoryURL: libraryDirectoryURL
        )
    }

    static func make(
        bundleIdentifier: String?,
        appBundleURL: URL,
        appNameCandidates: [String],
        libraryDirectoryURL: URL
    ) throws -> AppUninstallCleanupPlan {
        guard let bundleIdentifier = normalizedName(bundleIdentifier) else {
            throw AppUninstallCleanupPlanError.missingBundleIdentifier
        }

        let libraryURL = libraryDirectoryURL.standardizedFileURL
        let appNames = uniqueNames(appNameCandidates + ["Tabby", "tabby"])
        let supportNames = uniqueNames(appNames + [bundleIdentifier])
        let applicationSupportURL = libraryURL.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let cachesURL = libraryURL.appendingPathComponent("Caches", isDirectory: true)
        let logsURL = libraryURL.appendingPathComponent("Logs", isDirectory: true)
        let byHostPreferencesURL =
            libraryURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("ByHost", isDirectory: true)

        var urls: [URL] = []
        for supportName in supportNames {
            urls.append(
                applicationSupportURL.appendingPathComponent(supportName, isDirectory: true)
            )
        }

        for appName in appNames {
            urls.append(logsURL.appendingPathComponent(appName, isDirectory: true))
        }

        urls.append(cachesURL.appendingPathComponent(bundleIdentifier, isDirectory: true))
        urls.append(
            cachesURL
                .appendingPathComponent("Sparkle", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        )
        urls.append(
            libraryURL
                .appendingPathComponent("HTTPStorages", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        )
        urls.append(
            libraryURL
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
        )
        urls.append(
            libraryURL
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
        )
        urls.append(
            libraryURL
                .appendingPathComponent("Application Scripts", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        )
        urls.append(
            libraryURL
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        )

        return AppUninstallCleanupPlan(
            bundleIdentifier: bundleIdentifier,
            appBundleURL: appBundleURL.standardizedFileURL,
            removableDataURLs: uniqueURLs(urls),
            byHostPreferencesDirectoryURL: byHostPreferencesURL.standardizedFileURL,
            byHostPreferencesFilenamePrefix: "\(bundleIdentifier)."
        )
    }

    private static func appNameCandidates(from bundle: Bundle) -> [String] {
        [
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            bundle.bundleURL.deletingPathExtension().lastPathComponent,
        ].compactMap { $0 }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seenNames = Set<String>()
        var uniqueNames: [String] = []

        for name in names {
            guard let normalized = normalizedName(name),
                  seenNames.insert(normalized).inserted
            else {
                continue
            }

            uniqueNames.append(normalized)
        }

        return uniqueNames
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else {
                continue
            }

            uniqueURLs.append(standardizedURL)
        }

        return uniqueURLs
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let name else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }
}

enum AppUninstallCleanupPlanError: LocalizedError, Equatable {
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "Tabby could not determine its bundle identifier."
        }
    }
}
