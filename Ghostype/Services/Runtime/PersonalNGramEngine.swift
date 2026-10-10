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
/// - Also builds a prefix index: given a partial word ("hel"), the most likely completion ("hello").
/// - Both are synchronous hash lookups, <1ms. No async, no inference.
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
    
    /// prefix (lowercased) -> [(word, count)], for word completion. Only prefixes of length 2+.
    private let prefixIndex: [String: [(word: String, count: Int)]]
    
    /// Minimum times a trigram must appear to be trusted. Filters noise.
    private static let minTrigramCount = 2
    /// Minimum times a word must appear to be in the prefix index.
    private static let minWordCount = 3
    /// Maximum candidates stored per key. Bounds memory.
    private static let maxCandidatesPerKey = 5
    
    init(trigrams: [String: [(word: String, count: Int)]] = [:],
         prefixIndex: [String: [(word: String, count: Int)]] = [:]) {
        self.trigrams = trigrams
        self.prefixIndex = prefixIndex
    }
    
    /// Builds an engine from the user's typed texts. Call on a background thread;
    /// the result is immutable and Sendable.
    static func build(from texts: [String]) -> PersonalNGramEngine {
        var trigramCounts: [String: [String: Int]] = [:]
        var wordCounts: [String: Int] = [:]
        
        for text in texts {
            let words = tokenize(text)
            guard words.count >= 1 else { continue }
            
            // Count individual words for the prefix index.
            for word in words {
                wordCounts[word, default: 0] += 1
            }
            
            // Build trigrams: (w1, w2) -> w3
            guard words.count >= 3 else { continue }
            for i in 0..<(words.count - 2) {
                let key = trigramKey(words[i], words[i + 1])
                trigramCounts[key, default: [:]][words[i + 2], default: 0] += 1
            }
        }
        
        // Convert to sorted, bounded arrays.
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
        
        return PersonalNGramEngine(trigrams: trigrams, prefixIndex: prefixIndex)
    }
    
    /// Predicts the next word after the given two words. Returns nil if no confident prediction.
    /// Synchronous, <1ms.
    func predictNext(after w1: String, _ w2: String) -> String? {
        let key = Self.trigramKey(normalize(w1), normalize(w2))
        return trigrams[key]?.first?.word
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
        if let next = predictNext(after: w1, w2) {
            return " " + next
        }
        return nil
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
