import XCTest
@testable import Ghostype

final class AppAcceptanceLearningTests: XCTestCase {
    func testOnlyAppsWithEnoughIgnoredSuggestionsWaitLonger() {
        typealias Counts = AppAcceptanceLearning.Counts
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(for: nil), 0)
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(for: Counts(shown: 39, accepted: 0)), 0)
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(for: Counts(shown: 40, accepted: 1)),
                       AppAcceptanceLearning.quietExtraDelayMilliseconds)
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(for: Counts(shown: 40, accepted: 2)), 0)
    }

    func testCountsHalvePastTheDecayThreshold() {
        let start = AppAcceptanceLearning.Counts(shown: AppAcceptanceLearning.decayThreshold, accepted: 10)
        let next = AppAcceptanceLearning.recorded(start) { $0.shown += 1 }
        XCTAssertEqual(next, AppAcceptanceLearning.Counts(shown: 200, accepted: 5))
    }

    func testRecordsPerAppAndRespectsTheToggle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppAcceptanceLearningTests"))
        defaults.removePersistentDomain(forName: "AppAcceptanceLearningTests")
        for _ in 0..<40 { AppAcceptanceLearning.recordShown(bundleIdentifier: "com.quiet", defaults: defaults) }
        AppAcceptanceLearning.recordShown(bundleIdentifier: "com.busy", defaults: defaults)
        AppAcceptanceLearning.recordAccepted(bundleIdentifier: "com.busy", defaults: defaults)

        XCTAssertEqual(AppAcceptanceLearning.allCounts(defaults)["com.busy"], .init(shown: 1, accepted: 1))
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(bundleIdentifier: "com.quiet", defaults: defaults),
                       AppAcceptanceLearning.quietExtraDelayMilliseconds)
        defaults.set(false, forKey: AppAcceptanceLearning.enabledKey)
        XCTAssertEqual(AppAcceptanceLearning.extraDelayMilliseconds(bundleIdentifier: "com.quiet", defaults: defaults), 0)
        defaults.removePersistentDomain(forName: "AppAcceptanceLearningTests")
    }
}
