import Foundation

/// File overview:
/// The user's own names and terms (Settings > Writing > Personal Dictionary). Stored as one
/// comma- or line-separated string so the settings field binds straight to `@AppStorage`.
/// Three consumers read it per request: the typo gate never "corrects" a listed term, the local
/// word-ending fallback can complete one from its first letters, and the prompt's learned
/// vocabulary section lists them so the model spells them the user's way.
nonisolated enum PersonalDictionary {
    static let defaultsKey = "ghostypePersonalDictionary"
    /// Keeps the prompt section and the per-keystroke lookups bounded.
    static let maximumTerms = 200

    static func terms(from raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maximumTerms)
            .map { $0 }
    }

    static func terms(_ defaults: UserDefaults) -> [String] {
        terms(from: defaults.string(forKey: defaultsKey) ?? "")
    }

    /// Case-insensitive, so "ghostype" typed at a sentence start or in lowercase still counts.
    static func contains(_ word: String, in terms: [String]) -> Bool {
        terms.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}
