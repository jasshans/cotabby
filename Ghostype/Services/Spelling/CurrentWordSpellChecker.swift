import AppKit
import Foundation

/// File overview:
/// Thin wrapper around `NSSpellChecker` for the typo gate. We isolate the AppKit dependency here so
/// the prediction pipeline depends on a focused, testable surface rather than `NSSpellChecker`
/// directly, and so the spell document tag is owned in exactly one place.
///
/// Why native spell-check (not the LLM) for both detection and correction:
/// - Detection must be deterministic and cheap; it is the same engine the system underlines with.
/// - The Open Source path drives a base model that does not follow instruction prompts, so an
///   LLM "give me the corrected word" prompt is unreliable there. The native ranked guesses are
///   instant, offline, and good enough for single-word spelling fixes.
///
/// Known limit, by design: `NSSpellChecker` only flags non-words, so real-word errors (`their` vs
/// `there`) are never detected. That is out of scope here.
@MainActor
final class CurrentWordSpellChecker {
    /// Document tag identifies our "spell session" inside `NSSpellChecker.shared`. A unique tag
    /// avoids cross-contamination with whatever spellcheck state other apps have armed.
    private let documentTag: Int

    /// Memoized verdicts for `isTypo`, `hasCompletions`, and `nativeCorrections`.
    /// `NSSpellChecker` calls cross into the spell server (XPC/IPC), and the typo gate
    /// queries the same word multiple times per generation cycle (detect, then correct,
    /// then the seam guard re-checks). Caching per word collapses those repeat calls
    /// to one. Bounded to avoid unbounded growth during long sessions; eviction is
    /// FIFO (oldest first) which is fine because typing is temporally local.
    /// Note: the cache is not invalidated on system language changes — the checker
    /// uses `language: nil` (system preference), and a language switch mid-session
    /// is rare enough that stale verdicts for recently-typed words are acceptable.
    private var typoCache: [String: Bool] = [:]
    private var completionsCache: [String: Bool] = [:]
    private var correctionsCache: [String: [String]] = [:]
    private static let maxCacheEntries = 500

    init() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        // We deliberately do not mutate `NSSpellChecker.shared` (e.g. forcing
        // `automaticallyIdentifiesLanguages`): that flag is app-global shared state, and overriding
        // it here would silently change behavior for any future text-checking context. We pass
        // `language: nil` on every call instead, which respects the shared checker's existing
        // language configuration (the user's system spelling preference, which already enables
        // automatic-by-language detection by default on modern macOS).
    }

    /// Returns true when `NSSpellChecker` considers the entire word misspelled. We require the
    /// returned range to start at offset 0 and cover the whole word; otherwise we would misfire on
    /// tokens like `I'm` where only part of the token is flagged, and on tokens that carry trailing
    /// punctuation (`nmae,`) where the flagged range stops short of the punctuation.
    func isTypo(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if let cached = typoCache[word] { return cached }
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        guard misspelledRange.location == 0 else {
            typoCache[word] = false
            evictIfNeeded()
            return false
        }
        let result = misspelledRange.length == (word as NSString).length
        typoCache[word] = result
        evictIfNeeded()
        return result
    }

    /// True when `partialWord` is the beginning of at least one dictionary word: the user is still
    /// typing it. Distinguishes "apprec" (in progress) from "nmae" (a typo) for the typo gate.
    func hasCompletions(forPartialWord partialWord: String) -> Bool {
        guard partialWord.count >= 2 else { return false }
        if let cached = completionsCache[partialWord] { return cached }
        let fullRange = NSRange(location: 0, length: (partialWord as NSString).length)
        let completions = NSSpellChecker.shared.completions(
            forPartialWordRange: fullRange,
            in: partialWord,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []
        let lowered = partialWord.lowercased()
        let result = completions.contains { $0.count > partialWord.count && $0.lowercased().hasPrefix(lowered) }
        completionsCache[partialWord] = result
        evictIfNeeded()
        return result
    }

    /// `NSSpellChecker`'s own ranked corrections for the word (best first), or an empty array when it
    /// has nothing to offer.
    func nativeCorrections(for word: String) -> [String] {
        if let cached = correctionsCache[word] { return cached }
        let fullRange = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: fullRange,
            in: word,
            language: nil,
            inSpellDocumentWithTag: documentTag
        )
        let result = guesses ?? []
        correctionsCache[word] = result
        evictIfNeeded()
        return result
    }

    /// The single instant correction to offer for `word`: the top native guess that is a different
    /// single word, recased to match the typo's capitalization. `nil` when there is no usable guess.
    func bestCorrection(for word: String) -> String? {
        let candidate = nativeCorrections(for: word)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { candidate in
                !candidate.isEmpty
                    && candidate.lowercased() != word.lowercased()
                    // Single-word fixes only: a guess containing a space would change the field's
                    // word count and break the one-word-replace delete math on accept.
                    && !candidate.contains(" ")
            }
        guard let candidate else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: candidate)
    }

    /// Evicts the oldest entries when any cache exceeds the cap. Called after each
    /// insertion. FIFO eviction via `Dictionary` ordering is not guaranteed, so we
    /// remove an arbitrary subset — correctness doesn't depend on which entries go,
    /// only that the cache stays bounded.
    private func evictIfNeeded() {
        if typoCache.count > Self.maxCacheEntries {
            typoCache.removeValue(forKey: typoCache.keys.first ?? "")
        }
        if completionsCache.count > Self.maxCacheEntries {
            completionsCache.removeValue(forKey: completionsCache.keys.first ?? "")
        }
        if correctionsCache.count > Self.maxCacheEntries {
            correctionsCache.removeValue(forKey: correctionsCache.keys.first ?? "")
        }
    }
}
