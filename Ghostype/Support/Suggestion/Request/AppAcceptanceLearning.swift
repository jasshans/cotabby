import Foundation

/// File overview:
/// Per-app learning of where suggestions get accepted. Each app keeps a shown/accepted count;
/// once an app has shown enough suggestions with almost none taken, Ghostype waits for a longer
/// typing pause there before generating. That skips decodes the user ignores anyway (battery)
/// and keeps apps where suggestions are welcome at full pace. One accepted suggestion in a while
/// is enough to keep an app at the normal pace, and counts halve as they grow so recent behaviour
/// outweighs old habits.
nonisolated enum AppAcceptanceLearning {
    static let enabledKey = "ghostypeSpeedLearnAppAcceptance"
    static let countsKey = "ghostypeAppAcceptanceCounts"
    /// Shown suggestions an app needs before its rate means anything.
    static let minimumShown = 40
    /// Below this acceptance rate an app counts as one where suggestions are mostly ignored.
    static let quietAcceptanceRate = 0.05
    /// Extra pause before generating in such an app.
    static let quietExtraDelayMilliseconds = 250
    /// Counts halve past this many shown suggestions, so the rate tracks recent use.
    static let decayThreshold = 400

    struct Counts: Codable, Equatable {
        var shown = 0
        var accepted = 0
    }

    /// Default ON: the only effect is a slightly longer pause in apps where you ignore suggestions.
    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func extraDelayMilliseconds(for counts: Counts?) -> Int {
        guard let counts, counts.shown >= minimumShown else { return 0 }
        let rate = Double(counts.accepted) / Double(counts.shown)
        return rate < quietAcceptanceRate ? quietExtraDelayMilliseconds : 0
    }

    static func extraDelayMilliseconds(bundleIdentifier: String?, defaults: UserDefaults) -> Int {
        guard let bundleIdentifier, isEnabled(defaults) else { return 0 }
        return extraDelayMilliseconds(for: allCounts(defaults)[bundleIdentifier])
    }

    static func recordShown(bundleIdentifier: String?, defaults: UserDefaults) {
        update(bundleIdentifier, defaults) { $0.shown += 1 }
    }

    static func recordAccepted(bundleIdentifier: String?, defaults: UserDefaults) {
        update(bundleIdentifier, defaults) { $0.accepted += 1 }
    }

    static func recorded(_ counts: Counts, applying change: (inout Counts) -> Void) -> Counts {
        var updated = counts
        change(&updated)
        if updated.shown > decayThreshold {
            updated.shown /= 2
            updated.accepted /= 2
        }
        updated.accepted = min(updated.accepted, updated.shown)
        return updated
    }

    static func allCounts(_ defaults: UserDefaults) -> [String: Counts] {
        guard let data = defaults.data(forKey: countsKey),
              let decoded = try? JSONDecoder().decode([String: Counts].self, from: data) else { return [:] }
        return decoded
    }

    private static func update(_ bundleIdentifier: String?, _ defaults: UserDefaults, _ change: (inout Counts) -> Void) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        var all = allCounts(defaults)
        all[bundleIdentifier] = recorded(all[bundleIdentifier] ?? Counts(), applying: change)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: countsKey)
        }
    }
}
