import XCTest
@testable import Ghostype

/// Tests for the typo gate that runs before each prediction. A correction is only ever offered
/// (accepted with Tab), never applied, and a flagged word without a correction never hides
/// predictions. Spell-check behavior is stubbed, so each case pins one branch.
final class TypoGateTests: XCTestCase {
    private func resolve(
        precedingText: String,
        offer: Bool = true,
        typos: Set<String> = [],
        corrections: [String: String] = [:]
    ) -> TypoGateDecision {
        TypoGate.resolve(
            precedingText: precedingText,
            settings: TypoGate.Settings(offerTypoCorrections: offer),
            isTypo: { typos.contains($0) },
            bestCorrection: { corrections[$0] }
        )
    }

    func test_pausedPrefixNeverCallsSpellingOrCorrection() {
        for prefix in ["wri", "becau", "recomm", "car"] {
            let decision = TypoGate.resolve(precedingText: "I typed " + prefix,
                settings: .init(offerTypoCorrections: true),
                isTypo: { _ in XCTFail("Unfinished words must not be spell-checked"); return true },
                bestCorrection: { _ in XCTFail("Unfinished words must not be corrected"); return "wrong" })
            XCTAssertEqual(decision, .proceed)
        }
    }

    func test_offersCorrectionAfterSpaceOrPunctuation() {
        for text in ["hi nmae ", "hi nmae,", "hi nmae!"] {
            XCTAssertEqual(resolve(precedingText: text, typos: ["nmae"], corrections: ["nmae": "name"]),
                           .offerCorrection(word: "nmae", correctedWord: "name"), text)
        }
    }

    func test_neverHidesPredictionsForAFlaggedWordWithoutCorrection() {
        // Names and words in other languages: predictions continue.
        XCTAssertEqual(resolve(precedingText: "ask Ghostype ", typos: ["Ghostype"]), .proceed)
    }

    func test_offersNothingWhenCorrectionsAreOff() {
        XCTAssertEqual(resolve(precedingText: "hi nmae ", offer: false, typos: ["nmae"],
                               corrections: ["nmae": "name"]), .proceed)
    }

    func test_proceedsWhenTrailingTokenIsNotAWord() {
        XCTAssertEqual(resolve(precedingText: "ping 99 ", typos: ["99"], corrections: ["99": "go"]), .proceed)
    }

    func test_proceedsWhenTypoFollowedByTwoSpaces() {
        XCTAssertEqual(resolve(precedingText: "hi nmae  ", typos: ["nmae"], corrections: ["nmae": "name"]), .proceed)
    }
}
