import Foundation

/// A personal trigram language model built from the user's typing history.
///
/// Why this exists: LLM inference takes 500ms-2s per suggestion. Cotypist feels "instant"
/// because it doesn't wait for the model on every keystroke. This engine predicts the next
/// word in microseconds via hash lookup — the "fast" layer that makes the stream feel alive,
/// with the LLM as background refinement for novel contexts.
///
/// How it works:
/// - From typing history, builds P(w3 | w1, w2): given the last two words, the most likely next.
/// - Bigram fallback P(w3 | w2) when no trigram fires: denser, engages on thinner history.
/// - Chains predictions into multi-word ghosts ("to hearing from you"): each step feeds
///   the next, so familiar phrases complete as whole sentences, Cotypist-style.
/// - Also builds a prefix index: given a partial word ("hel"), the most likely completion ("hello").
/// - All synchronous hash lookups, <1ms total. No async, no inference.
///
/// This is how phone keyboards do autocomplete — they don't run an LLM per keystroke.
/// The LLM is the "smart" layer; the n-gram is the "fast" layer.
///
/// Privacy: built entirely from the user's own typing history (already encrypted on disk).
/// No data leaves the device. The index lives in memory only.
///
/// Threading: build on a background thread via `rebuild(from:)`. `predict` is lock-free
/// read-only and safe to call from any thread.
final class PersonalNGramEngine: Sendable {
    /// (w1 + "\u{1F}" + w2) -> [(w3, count)], sorted by count descending.
    /// The unit separator is a safe key delimiter (never appears in words).
    private let trigrams: [String: [(word: String, count: Int)]]
    /// w1 -> [(w2, count)]: bigram fallback when no trigram fires. Denser, so it
    /// engages on thinner history.
    private let bigrams: [String: [(word: String, count: Int)]]

    /// prefix (lowercased) -> [(word, count)], for word completion. Only prefixes of length 2+.
    private let prefixIndex: [String: [(word: String, count: Int)]]

    /// Minimum times a trigram must appear to be trusted. Filters noise.
    private static let minTrigramCount = 2
    /// Minimum times a bigram must appear to be trusted.
    private static let minBigramCount = 2
    /// Minimum times a word must appear to be in the prefix index.
    private static let minWordCount = 2
    /// Maximum candidates stored per key. Bounds memory.
    private static let maxCandidatesPerKey = 5
    /// Maximum words in one chained ghost. Bounds runaway predictions.
    private static let maxChainWords = 8

    init(trigrams: [String: [(word: String, count: Int)]] = [:],
         bigrams: [String: [(word: String, count: Int)]] = [:],
         prefixIndex: [String: [(word: String, count: Int)]] = [:]) {
        self.trigrams = trigrams
        self.bigrams = bigrams
        self.prefixIndex = prefixIndex
    }

    /// Builds an engine from the user's typed texts. Call on a background thread;
    /// the result is immutable and Sendable.
    static func build(from texts: [String]) -> PersonalNGramEngine {
        var trigramCounts: [String: [String: Int]] = [:]
        var bigramCounts: [String: [String: Int]] = [:]
        var wordCounts: [String: Int] = [:]

        for text in texts {
            let words = tokenize(text)
            guard words.count >= 1 else { continue }

            // Count individual words for the prefix index.
            for word in words {
                wordCounts[word, default: 0] += 1
            }

            // Build trigrams: (w1, w2) -> w3
            if words.count >= 3 {
                for index in 0..<(words.count - 2) {
                    let key = trigramKey(words[index], words[index + 1])
                    trigramCounts[key, default: [:]][words[index + 2], default: 0] += 1
                }
            }

            // Build bigrams: w1 -> w2 (fallback when no trigram fires)
            if words.count >= 2 {
                for index in 0..<(words.count - 1) {
                    bigramCounts[words[index], default: [:]][words[index + 1], default: 0] += 1
                }
            }
        }

        // Convert to sorted, bounded arrays.
        let trigrams = Self.boundedTrigramCandidates(from: trigramCounts)
        let bigrams = Self.boundedBigramCandidates(from: bigramCounts)

        // Build prefix index from frequent words.
        var prefixIndex: [String: [(word: String, count: Int)]] = [:]
        let frequentWords = wordCounts.filter { $0.value >= minWordCount }
        for (word, count) in frequentWords {
            // Index all prefixes of length 2..<(word length).
            // E.g., "hello" -> "he", "hel", "hell".
            let lower = word.lowercased()
            guard lower.count >= 3 else { continue }
            for len in 2..<lower.count {
                let prefix = String(lower.prefix(len))
                prefixIndex[prefix, default: []].append((word: word, count: count))
            }
        }
        // Sort and bound each prefix bucket.
        for key in prefixIndex.keys {
            prefixIndex[key] = Array(
                prefixIndex[key]!
                    .sorted { $0.count > $1.count }
                    .prefix(maxCandidatesPerKey)
            )
        }

        return PersonalNGramEngine(trigrams: trigrams, bigrams: bigrams, prefixIndex: prefixIndex)
    }

    /// Keeps the strongest candidates per trigram key, sorted by count and bounded.
    /// A separate method (rather than inline in `build`) because SwiftLint caps function
    /// complexity at 10 and `build(from:)` is already near that limit — folding this loop
    /// back in would fail CI on `cyclomatic_complexity`.
    private static func boundedTrigramCandidates(
        from trigramCounts: [String: [String: Int]]
    ) -> [String: [(word: String, count: Int)]] {
        var trigrams: [String: [(word: String, count: Int)]] = [:]
        for (key, candidates) in trigramCounts {
            let filtered = candidates
                .filter { $0.value >= minTrigramCount }
                .sorted { $0.value > $1.value }
                .prefix(maxCandidatesPerKey)
                .map { (word: $0.key, count: $0.value) }
            if !filtered.isEmpty {
                trigrams[key] = Array(filtered)
            }
        }
        return trigrams
    }

    /// Keeps the strongest candidates per bigram key, sorted by count and bounded.
    /// Extracted so `build(from:)` stays under SwiftLint's complexity cap.
    private static func boundedBigramCandidates(
        from bigramCounts: [String: [String: Int]]
    ) -> [String: [(word: String, count: Int)]] {
        var bigrams: [String: [(word: String, count: Int)]] = [:]
        for (key, candidates) in bigramCounts {
            let filtered = candidates
                .filter { $0.value >= minBigramCount }
                .sorted { $0.value > $1.value }
                .prefix(maxCandidatesPerKey)
                .map { (word: $0.key, count: $0.value) }
            if !filtered.isEmpty {
                bigrams[key] = Array(filtered)
            }
        }
        return bigrams
    }

    /// Predicts the next word after the given two words. Returns nil if no confident prediction.
    /// Synchronous, <1ms.
    func predictNext(after w1: String, _ w2: String) -> String? {
        let key = Self.trigramKey(normalize(w1), normalize(w2))
        return trigrams[key]?.first?.word
    }

    /// Predicts the next word with bigram fallback: trigram (w1,w2)->w3 first,
    /// then bigram (w2)->w3. The fallback is what makes the engine useful on thin
    /// history — bigrams need far fewer observations to be trustworthy.
    /// Synchronous, <1ms.
    func predictNextWord(after w1: String, _ w2: String) -> String? {
        if let hit = predictNext(after: w1, w2) { return hit }
        return bigrams[normalize(w2)]?.first?.word
    }

    /// Completes a partial word. E.g., "hel" -> "hello". Returns nil if no confident completion.
    /// Synchronous, <1ms.
    func completeWord(prefix: String) -> String? {
        let lower = prefix.lowercased()
        guard lower.count >= 2 else { return nil }
        // Don't suggest if the prefix is already a complete frequent word.
        return prefixIndex[lower]?.first?.word
    }

    /// The main entry point: given the text before the caret, predict what comes next.
    /// Returns the completion text (without leading space) or nil.
    /// Synchronous, <1ms.
    func predict(for precedingText: String) -> String? {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Case 1: caret is mid-word (e.g., "hel"). Complete the word.
        if let partialWord = Self.trailingPartialWord(in: precedingText) {
            if let completion = completeWord(prefix: partialWord) {
                // Return only the remainder, not the whole word.
                // E.g., prefix "hel", completion "hello" -> return "lo".
                let lowerPartial = partialWord.lowercased()
                let lowerCompletion = completion.lowercased()
                if lowerCompletion.hasPrefix(lowerPartial) && lowerCompletion.count > lowerPartial.count {
                    let remainder = String(completion.dropFirst(partialWord.count))
                    return remainder
                }
            }
            return nil
        }

        // Case 2: caret is at a word boundary (e.g., "looking forward "). Predict next word.
        let words = Self.tokenize(precedingText)
        guard words.count >= 2 else { return nil }
        let w1 = words[words.count - 2]
        let w2 = words[words.count - 1]
        if let next = predictNextWord(after: w1, w2) {
            return " " + next
        }
        return nil
    }

    /// Chains predictions into a multi-word ghost: "looking forward " -> "to hearing from you".
    /// Each step feeds the next ((w2,w3)->w4), so familiar phrases complete as whole
    /// sentences — the Cotypist-style "already suggesting the whole sentence" feel.
    /// Every step is a hash lookup; the whole chain is still <1ms. A visited-set stops
    /// degenerate loops ("the the the"), and maxChainWords bounds runaway ghosts.
    /// As the user types, each keystroke re-anchors the chain, so a wrong branch snaps
    /// back into place within a letter or two.
    /// Synchronous.
    func predictChain(for precedingText: String, maxWords: Int = maxChainWords) -> String? {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var words = Self.tokenize(precedingText)
        var parts: [String] = []
        // Mid-word caret: no leading space before the word remainder.
        let leadingSpace = Self.trailingPartialWord(in: precedingText) == nil

        if let partial = Self.trailingPartialWord(in: precedingText) {
            guard let completion = completeWord(prefix: partial),
                  completion.lowercased().hasPrefix(partial.lowercased()),
                  completion.count > partial.count
            else { return nil }
            parts.append(String(completion.dropFirst(partial.count)))
            words.append(completion.lowercased())
        }

        var visited = Set<String>()
        var chained = 0
        while chained < maxWords, words.count >= 2 {
            let w1 = words[words.count - 2]
            let w2 = words[words.count - 1]
            let stepKey = w1 + " " + w2
            guard !visited.contains(stepKey),
                  let next = predictNextWord(after: w1, w2)
            else { break }
            visited.insert(stepKey)
            if next == w2 { break } // immediate repetition: "the the"
            parts.append(next)
            words.append(next)
            chained += 1
        }

        guard !parts.isEmpty else { return nil }
        let glued = parts.joined(separator: " ")
        return leadingSpace ? " " + glued : glued
    }

    // MARK: - Private

    private static func trigramKey(_ w1: String, _ w2: String) -> String {
        w1 + "\u{1F}" + w2
    }

    private func normalize(_ word: String) -> String {
        word.lowercased()
    }

    /// Splits text into lowercase words. Simple whitespace/punctuation split.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Returns the partial word at the end of the text, if the caret is mid-word.
    /// E.g., "hello wo" -> "wo". Returns nil if at a word boundary.
    private static func trailingPartialWord(in text: String) -> String? {
        guard let last = text.last, last.isLetter || last.isNumber else {
            return nil // Ends with space/punctuation -> at word boundary.
        }
        // Walk back to the start of the current word.
        var start = text.endIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            let char = text[prev]
            if char.isLetter || char.isNumber || char == "'" {
                start = prev
            } else {
                break
            }
        }
        let word = String(text[start...])
        // Only consider it "partial" if it's not a complete word followed by space.
        // Since we already checked the last char is alphanumeric, this is mid-word.
        return word.isEmpty ? nil : word
    }
}
