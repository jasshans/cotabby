import Foundation

/// File overview:
/// Shared values for the encrypted on-device suggestion memory.
///
/// Suggestion memory is the "gets better the more you use it" half of Ghostype: every accepted or
/// dismissed suggestion teaches the app words and phrases this person actually uses, and that
/// learning survives restarts in an encrypted SQLite database (see `PersistentMemoryStore`,
/// upstream issue #446). These are the plain values that cross the boundary between the recorder,
/// the store, and the prompt builders. Nothing here touches the database, the Keychain, or the UI.
///
/// Why separate values instead of reusing the typing-history models: typing history stores whole
/// field texts for example retrieval; memory stores per-suggestion accept/reject signals and the
/// phrase statistics derived from them. The two answer different questions ("what did I write
/// that looks like this?" vs. "which words do I demonstrably reach for?") and evolve separately.
nonisolated enum MemoryEventKind: String, Sendable, CaseIterable {
    /// The user accepted a suggestion chunk (Tab / full-accept key).
    case accepted
    /// The user explicitly dismissed a suggestion (Esc) without accepting it.
    case rejected
    /// Reserved for future typed-text learning; not recorded today.
    case typed
}

/// One learning signal waiting to be persisted. A value type so the recorder can hand batches to
/// the store without sharing mutable state across threads.
nonisolated struct MemoryEvent: Sendable, Equatable {
    let kind: MemoryEventKind
    /// The accepted chunk, or the dismissed suggestion text.
    let text: String
    let bundleIdentifier: String
    let date: Date
}

/// A normalized phrase with its accumulated evidence, as handed to prompt builders.
nonisolated struct LearnedPhrase: Sendable, Equatable {
    let phrase: String
    let acceptCount: Int
    let rejectCount: Int
    let lastUsed: Date
    /// Acceptance evidence minus rejection evidence, decayed by recency (see
    /// `MemoryPhraseExtractor.score`). Higher means "more characteristic of this user right now".
    let score: Double
}

/// The memory feature's own preferences. Kept here rather than in `SuggestionSettingsModel` for
/// the same reason typing history keeps its own: they only matter to this subsystem, and keeping
/// them together keeps the enable toggle, the recording gate, and Clear Memory in one place.
nonisolated struct MemoryPreferences: Sendable, Equatable {
    var isEnabled: Bool

    static let defaults = MemoryPreferences(isEnabled: true)
}
