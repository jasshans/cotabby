import CryptoKit
import Foundation

/// File overview:
/// Pure phrase extraction and ranking for suggestion memory.
///
/// The learning model is deliberately simple and inspectable: from every accepted or rejected
/// suggestion chunk, extract normalized word n-grams (1–3 words); count accepts and rejects per
/// phrase; rank by net evidence decayed with recency. No embeddings, no model calls — the whole
/// thing is deterministic, testable without a database, and cheap enough to run on every keystroke
/// batch. The vocabulary that reaches prompts is the top of this ranking (see
/// `MemoryContextProvider`).
enum MemoryPhraseExtractor {
    /// Maximum words per learned phrase; longer spans are sentences, not vocabulary.
    static let maxWordsPerPhrase = 3
    /// Phrases longer than this are dropped: they bloat the prompt without teaching wording.
    static let maxPhraseCharacters = 64
    /// Cap on phrases extracted from a single event, bounding write amplification for long
    /// accepted texts.
    static let maxPhrasesPerEvent = 24
    /// Single words must carry signal: at least this many characters and contain a letter, so
    /// "the", "and", "2026" never become vocabulary.
    static let minSingleWordCharacters = 4

    /// Splits text into normalized candidate phrases: word n-grams for n in 1...3, lowercased with
    /// collapsed whitespace and edge punctuation trimmed, so "Hello," and "hello" accumulate as one
    /// phrase. Deduplicated within the event. Order is deterministic: all unigrams, then bigrams,
    /// then trigrams.
    static func phrases(from text: String) -> [String] {
        let words = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var seen = Set<String>()
        var phrases: [String] = []
        phrases.reserveCapacity(min(maxPhrasesPerEvent, words.count * maxWordsPerPhrase))
        for length in 1...maxWordsPerPhrase {
            guard words.count >= length else { break }
            for start in 0...(words.count - length) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                guard phrase.count <= maxPhraseCharacters else { continue }
                if length == 1, !isSignalWord(phrase) { continue }
                if seen.insert(phrase).inserted {
                    phrases.append(phrase)
                    if phrases.count >= maxPhrasesPerEvent { return phrases }
                }
            }
        }
        return phrases
    }

    /// Ranks a phrase: acceptance evidence minus rejection evidence, decayed by recency with a
    /// ~30-day half-life, so wording you stopped using fades instead of haunting prompts forever.
    /// A phrase with no net positive evidence scores 0 and never reaches the vocabulary.
    static func score(
        acceptCount: Int,
        rejectCount: Int,
        lastUsed: Date,
        now: Date = Date()
    ) -> Double {
        let net = Double(acceptCount - rejectCount)
        guard net > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(lastUsed) / 86_400)
        return net * pow(0.5, days / 30.0)
    }

    /// Stable primary key for `phrase_stats`: SHA-256 of the normalized phrase, hex-encoded. The
    /// hash (not the phrase) is the lookup key so indexing never touches plaintext; the encrypted
    /// phrase column carries the display form.
    static func phraseHash(_ phrase: String) -> String {
        let digest = SHA256.hash(data: Data(phrase.utf8))
        return digest.reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    private static func isSignalWord(_ word: String) -> Bool {
        word.count >= minSingleWordCharacters
            && word.rangeOfCharacter(from: .letters) != nil
    }
}
