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
/// Privacy is enforced at both ends: the recorder never writes secure-field text, the store
/// encrypts what it keeps, and this provider returns an empty vocabulary for the endpoint engine
/// (memory never leaves the Mac) and while the feature is off. The request factory drops the
/// vocabulary for endpoints a second time, so the guarantee does not depend on any one call site.
@MainActor
final class MemoryContextProvider: ObservableObject, SuggestionMemoryContextProviding {
    /// How many learned phrases reach the prompt builders. Small enough to fit the prompt budget
    /// (see `BaseCompletionPromptRenderer`'s learned-vocabulary section), large enough to carry
    /// real wording signal.
    static let vocabularyLimit = 50

    private let store: PersistentMemoryStore
    /// Checked on every read so disabling the feature takes effect immediately, even before the
    /// cache is refreshed.
    private let isEnabled: @MainActor () -> Bool

    @Published private(set) var cachedVocabulary: [String] = []

    init(store: PersistentMemoryStore, isEnabled: @escaping @MainActor () -> Bool) {
        self.store = store
        self.isEnabled = isEnabled
    }

    /// Synchronous read for the request-building path. The coordinator calls this next to
    /// `historyExamples(for:)`; it never touches the database.
    func vocabularyForPrompt(engine: SuggestionEngineKind) -> [String] {
        guard isEnabled(), engine != .openAICompatible else { return [] }
        return cachedVocabulary
    }

    /// Reloads the cache from the store. The SQLite work and all decryption run on a background
    /// thread; only the published assignment hops back to the main actor.
    func refresh() async {
        let phrases = await Task.detached(priority: .utility) { [store] in
            store.topPhrases(limit: Self.vocabularyLimit).map(\.phrase)
        }.value
        cachedVocabulary = phrases
    }
}
