import Foundation

/// Caches the prompt's preface head (history examples + learned vocabulary) across
/// keystrokes in a typing burst, so the KV-cache prefix hint stays maximal.
///
/// Why this exists: the history examples are retrieved per request using the current
/// text as the query. As the user types, the query changes, the examples change, the
/// preface bytes change, and the common-prefix KV hint collapses — forcing a full
/// re-prefill (~1s) on every keystroke. Freezing the head for the burst duration keeps
/// the preface byte-identical; only the caret prefix (at the prompt's end, highest
/// priority) changes, which is exactly what append-only KV reuse needs.
///
/// The tradeoff is deliberate: examples retrieved for the burst's first keystroke may
/// be slightly stale by its last. The caret prefix — the strongest signal — is always
/// fresh, and KeyType's ADR-053 validates that KV reuse wins over preface freshness.
///
/// Pure value type. The coordinator owns one instance, feeds it the focus identity key,
/// and invalidates it on focus/navigation changes (alongside the anchor cache).
struct PromptHeadBurstCache: Sendable {
    struct Head: Equatable, Sendable {
        let examples: [String]
        let vocabulary: [String]
    }

    /// How long a burst lasts without typing before the head is refreshed.
    static let defaultBurstWindow: TimeInterval = 2.0

    private struct Entry: Sendable {
        let head: Head
        let identityKey: String
        let capturedAt: Date
    }

    private var cached: Entry?

    /// Returns the cached head when it is still valid for this burst, else nil.
    /// A hit slides the window forward so continuous typing extends the burst;
    /// a pause longer than `burstWindow` expires it and the next request refreshes.
    mutating func head(
        for identityKey: String,
        now: Date = Date(),
        burstWindow: TimeInterval = defaultBurstWindow
    ) -> Head? {
        guard let cached,
              cached.identityKey == identityKey,
              now.timeIntervalSince(cached.capturedAt) <= burstWindow
        else {
            return nil
        }
        // Sliding window: the burst stays alive as long as keystrokes keep coming.
        self.cached = Entry(head: cached.head, identityKey: identityKey, capturedAt: now)
        return cached.head
    }

    mutating func store(_ head: Head, identityKey: String, now: Date = Date()) {
        cached = Entry(head: head, identityKey: identityKey, capturedAt: now)
    }

    mutating func invalidate() {
        cached = nil
    }
}
