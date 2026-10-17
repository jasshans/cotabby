import Foundation

/// File overview:
/// Holds one prompt section's value fixed for a field session so the prompt head stays
/// byte-identical while the user types, which is what lets the llama runtime reuse its KV cache.
///
/// An empty value is not pinned: a field that starts with nothing to show (no history yet) keeps
/// asking until it gets something, then holds it. A new session (another field, a refocus, or an
/// engine change) recomputes. Owned by `SuggestionCoordinator`, one per section.
struct PromptSectionPin {
    private var session: String?
    private var value: [String] = []

    mutating func resolve(session: String, compute: () -> [String]) -> [String] {
        if self.session == session, !value.isEmpty { return value }
        self.session = session
        value = compute()
        return value
    }
}
