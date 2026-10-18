import Foundation

/// File overview:
/// Pure decision rule for the typo gate that runs before each prediction. Extracted from
/// `SuggestionCoordinator` so the "suppress vs correct vs proceed" logic is unit-testable without
/// `NSSpellChecker` or a live AX snapshot: the coordinator passes the spell-check behaviors in as
/// closures, and tests pass deterministic stubs.
nonisolated enum TypoGateDecision: Equatable {
    /// No correction to offer for the current word. Proceed with a normal continuation.
    case proceed
    /// The just-finished word looks misspelled and a correction is available. Offer it as a
    /// replace-the-word suggestion the user accepts with Tab; `word` is the typo to replace and the
    /// accept path recomputes the edit from live text.
    case offerCorrection(word: String, correctedWord: String)
}

enum TypoGate {
    /// The user settings that shape the gate decision.
    struct Settings {
        let offerTypoCorrections: Bool
    }

    /// Resolves the gate decision for the trailing word of `precedingText`.
    ///
    /// A correction is only ever offered, never applied: Ghostype does not change the user's text
    /// without Tab. A flagged word with no correction (a name, a word in another language) no longer
    /// hides predictions either; it proceeds like any other word. `isTypo` and `bestCorrection` are
    /// injected so this stays pure: in production they wrap `CurrentWordSpellChecker`; in tests they
    /// are stubs. Before a delimiter nothing is eligible: a partial word reaches the engine unchanged.
    static func resolve(
        precedingText: String,
        settings: Settings,
        isTypo: (String) -> Bool,
        bestCorrection: (String) -> String?
    ) -> TypoGateDecision {
        // Tolerates one trailing space so a just-finished word keeps its green correction offer.
        guard settings.offerTypoCorrections,
              let current = CaretWordContext.committedWord(in: precedingText),
              isTypo(current.word),
              let corrected = bestCorrection(current.word) else {
            return .proceed
        }
        return .offerCorrection(word: current.word, correctedWord: corrected)
    }
}
