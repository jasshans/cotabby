import Combine
import Foundation

/// File overview:
/// The read path for suggestion memory: keeps an in-memory cache of the top learned phrases and
/// hands them to the prompt builders as a compact "learned vocabulary" section.
///
/// Why a cache instead of querying the store per request: the request path is hot (every
/// keystroke that triggers a prediction builds a request), and even a fast SQLite query plus up
/// to 50 AES-GCM decryptions does not belong in it. The cache is refreshed after every persist
/// batch and on launch, so it trails reality by at most the recorder's debounce window. Each
/// entry is a short phrase, so the whole cache is a few kilobytes.
///
/// The cache is per-app: `vocabularyForPrompt` takes the focused field's bundle identifier and
/// serves that app's vocabulary (falling back to the global aggregate for apps with no learned
/// phrases yet). The first request from a new bundle fires a background refresh; until it lands,
/// the global vocabulary answers. Bundle entries are capped so a user with many apps doesn't
/// accumulate unbounded caches.
///
/// Privacy is enforced at both ends: the recorder never writes secure-field text, the store
/// encrypts what it keeps, and this provider returns an empty vocabulary for the endpoint engine
/// (memory never leaves the Mac) and while the feature is off. The request factory drops the
/// vocabulary for endpoints a second time, so the guarantee does not depend on any one call site.
@MainActor
final class MemoryContextProvider: ObservableObject, SuggestionMemoryContextProviding {
    /// Cap on per-bundle cache entries (plus the global one). Vocabulary is small; this bounds
    /// memory for users who switch between many apps.
    private static let maxCachedBundles = 8
    /// Cache key for the global cross-app aggregate.
    private static let globalCacheKey = ""

    private let store: PersistentMemoryStore
    /// Checked on every read so disabling the feature takes effect immediately, even before the
    /// cache is refreshed.
    private let isEnabled: @MainActor () -> Bool
    /// Personalization strength: sizes the vocabulary. Read per refresh so the slider takes
    /// effect without an app restart.
    private let strength: @MainActor () -> PersonalizationStrength

    @Published private(set) var cachedVocabulary: [String] = []
    /// Per-bundle vocabularies; `globalCacheKey` holds the cross-app aggregate.
    private var cachedVocabularies: [String: [String]] = [:]
    /// Bundle whose vocabulary was last requested; drives background refreshes.
    private var lastRequestedBundleKey = globalCacheKey

    init(
        store: PersistentMemoryStore,
        isEnabled: @escaping @MainActor () -> Bool,
        strength: @escaping @MainActor () -> PersonalizationStrength
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.strength = strength
    }

    /// Synchronous read for the request-building path. The coordinator calls this next to
    /// `historyExamples(for:)`; it never touches the database.
    func vocabularyForPrompt(engine: SuggestionEngineKind, bundleIdentifier: String?) -> [String] {
        guard isEnabled(), engine != .openAICompatible else { return [] }
        let key = Self.cacheKey(for: bundleIdentifier)
        if key != lastRequestedBundleKey {
            lastRequestedBundleKey = key
            // First request from this bundle: refresh in the background. The hot path never
            // waits on SQLite; the global vocabulary answers until the app's own lands.
            Task { [weak self] in await self?.refresh(bundleIdentifier: bundleIdentifier) }
        }
        return cachedVocabularies[key] ?? cachedVocabularies[Self.globalCacheKey] ?? []
    }

    /// Legacy single-vocabulary read (global aggregate). Kept for call sites that don't know
    /// the focused app.
    func vocabularyForPrompt(engine: SuggestionEngineKind) -> [String] {
        vocabularyForPrompt(engine: engine, bundleIdentifier: nil)
    }

    /// Reloads the cache from the store. The SQLite work and all decryption run on a background
    /// thread; only the published assignment hops back to the main actor.
    func refresh() async {
        await refresh(bundleIdentifier: nil)
    }

    /// Reloads the global vocabulary plus one bundle's. Called after persists (via
    /// `onDidPersist`, which passes the last-requested bundle) and on first request from a
    /// new bundle.
    func refresh(bundleIdentifier: String?) async {
        let key = Self.cacheKey(for: bundleIdentifier)
        let limit = strength().phraseLimit
        async let globalPhrases: [String] = Task.detached(priority: .utility) { [store] in
            store.topPhrases(limit: limit).map(\.phrase)
        }.value
        let bundlePhrases: [String]?
        if key == Self.globalCacheKey {
            bundlePhrases = nil
        } else {
            bundlePhrases = await Task.detached(priority: .utility) { [store] in
                store.topPhrases(limit: limit, bundleId: key).map(\.phrase)
            }.value
        }
        let global = await globalPhrases
        cachedVocabularies[Self.globalCacheKey] = global
        if let bundlePhrases {
            cachedVocabularies[key] = bundlePhrases
            // Bound the per-bundle cache: keep the global entry plus the most recently used
            // bundles. (Dictionary order is unstable, so evict arbitrary non-global, non-current
            // entries; correctness never depends on which survive.)
            while cachedVocabularies.count > Self.maxCachedBundles + 1 {
                if let evict = cachedVocabularies.keys.first(where: {
                    $0 != Self.globalCacheKey && $0 != key && $0 != lastRequestedBundleKey
                }) {
                    cachedVocabularies.removeValue(forKey: evict)
                } else {
                    break
                }
            }
        }
        // Keep the legacy published property pointed at the global vocabulary for any UI that
        // still reads it.
        cachedVocabulary = global
    }

    /// Re-reads whatever bundle was last requested (plus global). The `onDidPersist` hook calls
    /// this so new learning lands in the current app's vocabulary without knowing the bundle.
    func refreshCurrent() async {
        let bundle: String? = lastRequestedBundleKey == Self.globalCacheKey
            ? nil : lastRequestedBundleKey
        await refresh(bundleIdentifier: bundle)
    }

    private static func cacheKey(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return globalCacheKey }
        return bundleIdentifier
    }
}
