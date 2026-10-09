import XCTest
@testable import Ghostype

/// Tests for the per-day accepted word counts: bucketing, the all-time total, history windows,
/// persistence, and pruning. Mirrors the production defaults keys so a silent rename fails here.
@MainActor
final class DailyCompletionStatsTests: XCTestCase {
    /// Persisted-blob key, mirrored from the production constant so a silent rename fails here.
    private static let dailyKey = "cotabbyDailyAcceptedWordCounts"
    private static let legacyTotalKey = "cotabbyTotalAcceptedWordCount"

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CotabbyTests.dailyStats.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func date(daysAgo offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
    }

    func testRecordedWordsBucketIntoToday() {
        let store = DailyCompletionStats(userDefaults: freshDefaults())

        store.recordAcceptedWords(12)
        store.recordAcceptedWords(8)

        XCTAssertEqual(store.todayCount, 20)
        XCTAssertEqual(store.count(for: Date()), 20)
        XCTAssertEqual(store.recentDays(limit: 1).first?.count, 20)
    }

    func testZeroAndNegativeCountsAreIgnored() {
        let store = DailyCompletionStats(userDefaults: freshDefaults())

        store.recordAcceptedWords(0)
        store.recordAcceptedWords(-5)

        XCTAssertEqual(store.todayCount, 0)
    }

    func testWordsBucketIntoTheirOwnDay() {
        let store = DailyCompletionStats(userDefaults: freshDefaults())
        let yesterday = date(daysAgo: 1)

        store.recordAcceptedWords(30, on: yesterday)
        store.recordAcceptedWords(10)

        XCTAssertEqual(store.count(for: yesterday), 30)
        XCTAssertEqual(store.todayCount, 10)
    }

    func testAllTimeTotalIncludesLegacySeed() {
        let defaults = freshDefaults()
        defaults.set(1_000, forKey: Self.legacyTotalKey)

        let store = DailyCompletionStats(userDefaults: defaults)
        store.recordAcceptedWords(25)

        XCTAssertEqual(store.allTimeTotal, 1_025)
    }

    func testRecentDaysAreContinuousAndTodayFirst() {
        let store = DailyCompletionStats(userDefaults: freshDefaults())
        store.recordAcceptedWords(7, on: date(daysAgo: 2))

        let history = store.recentDays(limit: 3)

        XCTAssertEqual(history.count, 3)
        XCTAssertTrue(Calendar.current.isDateInToday(history[0].date))
        // The middle day saw nothing: it still appears, with a zero count.
        XCTAssertEqual(history[1].count, 0)
        XCTAssertEqual(history[2].count, 7)
    }

    func testDayKeysSurviveARelaunch() {
        let defaults = freshDefaults()
        let yesterday = date(daysAgo: 1)

        let first = DailyCompletionStats(userDefaults: defaults)
        first.recordAcceptedWords(42, on: yesterday)
        first.recordAcceptedWords(3)

        let second = DailyCompletionStats(userDefaults: defaults)

        XCTAssertEqual(second.count(for: yesterday), 42)
        XCTAssertEqual(second.todayCount, 3)
        XCTAssertNotNil(defaults.data(forKey: Self.dailyKey))
    }

    func testHistoryIsPrunedToOneYear() throws {
        let defaults = freshDefaults()
        var seed: [String: Int] = [:]
        // 400 days of history: 35 more than the 365-day cap.
        for offset in 0..<400 {
            let key = DailyCompletionStats.dayKey(for: date(daysAgo: offset))
            seed[key] = 1
        }
        defaults.set(try JSONEncoder().encode(seed), forKey: Self.dailyKey)

        let store = DailyCompletionStats(userDefaults: defaults)

        XCTAssertLessThanOrEqual(store.recentDays(limit: 400).count, 400)
        // The oldest days were dropped; the most recent year survived.
        XCTAssertEqual(store.count(for: date(daysAgo: 364)), 1)
        XCTAssertEqual(store.count(for: date(daysAgo: 399)), 0)
    }

    func testDayKeyFormatIsStable() {
        // A fixed-format key keeps UserDefaults readable and sortable across locales.
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 9
        components.hour = 12
        let date = Calendar.current.date(from: components)!

        XCTAssertEqual(DailyCompletionStats.dayKey(for: date), "2026-10-09")
    }
}
