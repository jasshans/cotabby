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
    /// The user typed over a visible suggestion without accepting it: the shown wording was
    /// seen and not taken. Weaker negative evidence than an explicit dismissal.
    case softRejected
    /// Text the user typed themselves (from typing-history recordings). Positive evidence for
    /// the vocabulary the user actually produces; recorded with lower per-occurrence weight
    /// than accepts because of its volume.
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
    /// Times the user produced this phrase by typing it themselves (from typing-history
    /// recordings). Weaker per-occurrence evidence than an accept because of its volume, but
    /// it is what breaks the cold-start trap: a phrase you type fifty times is your vocabulary
    /// even if you never Tab-accepted it.
    let typedCount: Int
    let rejectCount: Int
    /// Times a visible suggestion carrying this phrase was typed over without being taken.
    /// Weaker negative evidence than an explicit Esc dismissal.
    let softRejectCount: Int
    let lastUsed: Date
    /// Evidence for minus evidence against, decayed by recency (see `MemoryPhraseExtractor.score`).
    /// Higher means "more characteristic of this user right now".
    let score: Double
}

/// The memory feature's own preferences. Kept here rather than in `SuggestionSettingsModel` for
/// the same reason typing history keeps its own: they only matter to this subsystem, and keeping
/// them together keeps the enable toggle, the recording gate, and Clear Memory in one place.
nonisolated struct MemoryPreferences: Sendable, Equatable {
    var isEnabled: Bool
    /// How strongly learned vocabulary nudges suggestions: the number of top phrases reaching
    /// the prompt. Low keeps only the most certain wording; High lets the full vocabulary
    /// condition the model. Mirrors the personalization strength slider in Cotypist.
    var strength: PersonalizationStrength

    static let defaults = MemoryPreferences(isEnabled: true, strength: .medium)
}

/// Personalization strength: how many learned phrases condition each suggestion.
nonisolated enum PersonalizationStrength: String, Sendable, CaseIterable {
    case low
    case medium
    case high

    /// Top-phrase count reaching the prompt. The renderer's character budget still caps the
    /// section, so High adds phrases only while they fit.
    var phraseLimit: Int {
        switch self {
        case .low: 15
        case .medium: 30
        case .high: 50
        }
    }
}
