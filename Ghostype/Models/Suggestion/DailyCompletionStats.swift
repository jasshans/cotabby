import Combine
import Foundation

/// File overview:
/// Answers "how many words did I complete per day": a small always-on store that buckets every
/// Tab-accepted word count into its local calendar day, persists the buckets in UserDefaults, and
/// publishes them for the menu-bar label and the Settings statistics section.
///
/// Why it exists as its own type: the coordinator already owns the all-time total
/// (`totalTabAcceptedWordCount`), but per-day bucketing needs calendar math, history pruning, and
/// midnight rollover — none of which belong in the acceptance state machine. The coordinator calls
/// `recordAcceptedWords(_:)` from the exact place it bumps the all-time total, so the two can
/// never drift apart; this store only ever *observes* acceptance events, it never drives them.
///
/// Data flow: `SuggestionCoordinator.recordAcceptedWords(from:)` →
/// `dailyCompletionStats.recordAcceptedWords(_:)` → `@Published countsByDay` →
/// `MenuBarStatusLabelView` (today's count) and the Appearance settings pane (today, total,
/// per-day history). Owned by `CotabbyAppEnvironment`, injected into the coordinator like
/// `SuggestionQualityMetricsStore`.
///
/// Privacy: only counts are stored — never the accepted text itself. A day key plus an integer
/// reveals typing volume, nothing about content.
@MainActor
final class DailyCompletionStats: ObservableObject {
    /// One calendar day's accepted word count, for the Settings history list.
    struct DayCount: Identifiable, Equatable {
        /// Stable identity for SwiftUI diffing: the "yyyy-MM-dd" day key.
        let dayKey: String
        /// Start of the day in the local time zone, for locale-aware display.
        let date: Date
        let count: Int

        var id: String { dayKey }

        /// Whether any words were completed this day. A named predicate keeps call sites from
        /// spelling `.count == 0`, which SwiftLint's `empty_count` rule flags even though
        /// `count` here is an `Int`, not a collection — hence `>= 1` instead of `> 0`.
        var hasCompletions: Bool { count >= 1 }
    }

    /// Accepted word counts keyed by local day ("yyyy-MM-dd"). Published so the menu-bar label
    /// and Settings update the moment a completion is accepted.
    @Published private(set) var countsByDay: [String: Int] = [:]

    private let userDefaults: UserDefaults
    /// The all-time total that predates per-day tracking, read once at launch from the
    /// coordinator's legacy key. `allTimeTotal` adds the daily buckets on top, so history from
    /// before this feature shipped is never lost.
    private let legacyTotalSeed: Int
    private var cancellables = Set<AnyCancellable>()

    private static let defaultsKey = "cotabbyDailyAcceptedWordCounts"
    /// Must stay identical to the coordinator's `totalTabAcceptedWordCountDefaultsKey`;
    /// duplicated here because Models must not depend on the App layer that owns the coordinator.
    private static let legacyTotalDefaultsKey = "cotabbyTotalAcceptedWordCount"
    /// Bound the persisted history so the blob cannot grow without limit.
    private static let maxStoredDays = 365

    /// A fixed-format day key ("2026-10-09") in the *local* time zone, so "today" means the
    /// user's today. `en_US_POSIX` keeps the format stable regardless of the user's locale.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Stored-property @MainActor classes deallocated inside app-hosted tests double-free without
    /// an explicitly nonisolated deinit (the isolated-deinit runtime path over-releases). Same
    /// workaround as the other main-actor stores exercised by tests.
    nonisolated deinit {}

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.legacyTotalSeed = userDefaults.integer(forKey: Self.legacyTotalDefaultsKey)
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            countsByDay = decoded
        }
        pruneHistory()
        // The app is often left running for days; without this, the menu-bar label would keep
        // showing yesterday's count after midnight until the next accepted completion.
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Recording

    /// Buckets an accepted word count into its local calendar day. Called by the coordinator for
    /// every Tab acceptance, alongside the all-time total bump.
    func recordAcceptedWords(_ count: Int, on date: Date = Date()) {
        guard count > 0 else { return }
        let key = Self.dayKey(for: date)
        countsByDay[key, default: 0] += count
        pruneHistory()
        persist()
    }

    // MARK: - Reading

    /// Words completed today (local calendar day). Drives the menu-bar label.
    var todayCount: Int {
        countsByDay[Self.dayKey(for: Date())] ?? 0
    }

    func count(for date: Date) -> Int {
        countsByDay[Self.dayKey(for: date)] ?? 0
    }

    /// All-time accepted words: the pre-feature total plus everything bucketed since.
    var allTimeTotal: Int {
        legacyTotalSeed + countsByDay.values.reduce(0, +)
    }

    /// The most recent `limit` calendar days, today first, including days with zero completions
    /// so the Settings history reads as a continuous streak rather than sparse dots.
    func recentDays(limit: Int = 14) -> [DayCount] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<limit).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return DayCount(
                dayKey: Self.dayKey(for: date),
                date: date,
                count: countsByDay[Self.dayKey(for: date)] ?? 0
            )
        }
    }

    // MARK: - Private

    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private func pruneHistory() {
        guard countsByDay.count > Self.maxStoredDays else { return }
        // Day keys sort lexicographically in chronological order ("yyyy-MM-dd"), so dropping
        // from the front discards the oldest days.
        let sortedKeys = countsByDay.keys.sorted()
        let overflow = sortedKeys.count - Self.maxStoredDays
        for key in sortedKeys.prefix(overflow) {
            countsByDay.removeValue(forKey: key)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(countsByDay) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
