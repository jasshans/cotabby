import XCTest
@testable import tabby

/// Tests for the pure uninstall path planner.
///
/// The destructive uninstall service is intentionally not exercised here. Instead, these tests
/// lock down the deterministic filesystem surface that the service consumes, which catches
/// accidental cleanup regressions without deleting real user data.
final class AppUninstallCleanupPlanTests: XCTestCase {
    func test_make_includesUserScopedDataLocations() throws {
        let libraryURL = URL(fileURLWithPath: "/tmp/TabbyTests/Home/Library", isDirectory: true)

        let plan = try AppUninstallCleanupPlan.make(
            bundleIdentifier: "com.example.tabby",
            appBundleURL: URL(fileURLWithPath: "/Applications/Tabby.app", isDirectory: true),
            appNameCandidates: ["tabby", "Tabby", "tabby", "  "],
            libraryDirectoryURL: libraryURL
        )

        let paths = Set(plan.removableDataURLs.map(\.path))

        XCTAssertEqual(plan.bundleIdentifier, "com.example.tabby")
        XCTAssertEqual(plan.userDefaultsDomain, "com.example.tabby")
        XCTAssertEqual(plan.appBundleURL.path, "/Applications/Tabby.app")
        XCTAssertEqual(
            plan.byHostPreferencesDirectoryURL.path,
            "/tmp/TabbyTests/Home/Library/Preferences/ByHost"
        )
        XCTAssertEqual(plan.byHostPreferencesFilenamePrefix, "com.example.tabby.")
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Application Support/tabby"))
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Application Support/Tabby"))
        XCTAssertTrue(
            paths.contains("/tmp/TabbyTests/Home/Library/Application Support/com.example.tabby")
        )
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Caches/com.example.tabby"))
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Caches/Sparkle/com.example.tabby"))
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/HTTPStorages/com.example.tabby"))
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Preferences/com.example.tabby.plist"))
        XCTAssertTrue(
            paths.contains(
                "/tmp/TabbyTests/Home/Library/Saved Application State/com.example.tabby.savedState"
            )
        )
        XCTAssertTrue(
            paths.contains("/tmp/TabbyTests/Home/Library/Application Scripts/com.example.tabby")
        )
        XCTAssertTrue(paths.contains("/tmp/TabbyTests/Home/Library/Containers/com.example.tabby"))
        XCTAssertEqual(paths.count, plan.removableDataURLs.count)
    }

    func test_make_rejectsMissingBundleIdentifier() {
        XCTAssertThrowsError(
            try AppUninstallCleanupPlan.make(
                bundleIdentifier: nil,
                appBundleURL: URL(fileURLWithPath: "/Applications/Tabby.app", isDirectory: true),
                appNameCandidates: ["Tabby"],
                libraryDirectoryURL: URL(fileURLWithPath: "/tmp/TabbyTests/Home/Library")
            )
        ) { error in
            XCTAssertEqual(
                error as? AppUninstallCleanupPlanError,
                .missingBundleIdentifier
            )
        }
    }
}
