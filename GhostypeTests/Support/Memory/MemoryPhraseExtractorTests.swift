import XCTest
@testable import Ghostype

/// Pure-function tests for the memory phrase extractor. The contract: normalization folds case
/// and punctuation so repeated wording accumulates under one key; n-grams are bounded in length
/// and count so one long paste cannot flood the database; and scoring rewards net acceptance
/// while letting stale wording decay away.
final class MemoryPhraseExtractorTests: XCTestCase {

    // MARK: - Extraction

    func test_normalizesCaseAndEdgePunctuation() {
        let phrases = MemoryPhraseExtractor.phrases(from: "Hello, hello! HELLO.")
        // Case and edge punctuation fold so the three tokens accumulate as one word;
        // n-grams (1–3) are still emitted per the extractor contract.
        XCTAssertEqual(phrases, ["hello", "hello hello", "hello hello hello"])
    }

    func test_extractsUniBiAndTrigrams() {
        let phrases = MemoryPhraseExtractor.phrases(from: "the quick brown fox")
        // "the" and "fox" are too short to be single-word signal, but survive in longer n-grams.
        XCTAssertTrue(phrases.contains("quick"))
        XCTAssertTrue(phrases.contains("brown"))
        XCTAssertFalse(phrases.contains("the"))
        XCTAssertTrue(phrases.contains("the quick"))
        XCTAssertTrue(phrases.contains("quick brown"))
        XCTAssertTrue(phrases.contains("the quick brown"))
        XCTAssertFalse(phrases.contains("the quick brown fox"))
    }

    func test_dropsNumericSingleWords() {
        let phrases = MemoryPhraseExtractor.phrases(from: "meeting in 2026")
        XCTAssertFalse(phrases.contains("2026"))
        XCTAssertTrue(phrases.contains("meeting"))
    }

    func test_emptyAndBlankTextYieldsNothing() {
        XCTAssertTrue(MemoryPhraseExtractor.phrases(from: "").isEmpty)
        XCTAssertTrue(MemoryPhraseExtractor.phrases(from: "   \n … ").isEmpty)
    }

    func test_capsPhrasesPerEvent() {
        let text = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let phrases = MemoryPhraseExtractor.phrases(from: text)
        XCTAssertEqual(phrases.count, MemoryPhraseExtractor.maxPhrasesPerEvent)
    }

    func test_longPhrasesAreDropped() {
        let longWord = String(repeating: "a", count: MemoryPhraseExtractor.maxPhraseCharacters + 1)
        let phrases = MemoryPhraseExtractor.phrases(from: "ok \(longWord)")
        XCTAssertFalse(phrases.contains(longWord))
    }

    // MARK: - Scoring

    func test_scoreIsNetEvidence() {
        let now = Date()
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 4, rejectCount: 1, lastUsed: now, now: now),
            3.0,
            accuracy: 1e-9
        )
    }

    func test_scoreIsZeroWithoutNetPositiveEvidence() {
        let now = Date()
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 1, rejectCount: 1, lastUsed: now, now: now), 0
        )
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 0, rejectCount: 3, lastUsed: now, now: now), 0
        )
    }

    func test_scoreDecaysWithThirtyDayHalfLife() {
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 4, rejectCount: 0, lastUsed: thirtyDaysAgo, now: now),
            2.0,
            accuracy: 1e-9
        )
    }

    func test_typedEvidenceCountsAtHalfWeight() {
        let now = Date()
        // Ten typed occurrences beat five accepts: typed is genuine production, just voluminous.
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 0, typedCount: 10, rejectCount: 0, lastUsed: now, now: now),
            5.0,
            accuracy: 1e-9
        )
        // Typed evidence alone still needs net positive: rejects cancel it.
        XCTAssertEqual(
            MemoryPhraseExtractor.score(acceptCount: 0, typedCount: 2, rejectCount: 1, lastUsed: now, now: now),
            0
        )
    }

    func test_softRejectsWeighHalfAgainstEvidence() {
        let now = Date()
        // Four soft rejects (typed over) erase two accepts' worth, not four.
        XCTAssertEqual(
            MemoryPhraseExtractor.score(
                acceptCount: 4, rejectCount: 0, softRejectCount: 4, lastUsed: now, now: now
            ),
            2.0,
            accuracy: 1e-9
        )
        // Soft rejects alone can't drive a phrase negative — they only cancel positive evidence.
        XCTAssertEqual(
            MemoryPhraseExtractor.score(
                acceptCount: 0, rejectCount: 0, softRejectCount: 10, lastUsed: now, now: now
            ),
            0
        )
    }

    // MARK: - Hashing

    func test_phraseHashIsStableHex() {
        let salt = Data(repeating: 0x42, count: 32)
        let first = MemoryPhraseExtractor.phraseHash("kind regards", salt: salt)
        let second = MemoryPhraseExtractor.phraseHash("kind regards", salt: salt)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(first, MemoryPhraseExtractor.phraseHash("kind regard", salt: salt))
    }

    func test_phraseHashDependsOnSalt() {
        // The per-database salt is what defeats precomputed dictionaries: the same phrase
        // must hash differently under different salts.
        let phrase = "kind regards"
        let a = MemoryPhraseExtractor.phraseHash(phrase, salt: Data(repeating: 0x42, count: 32))
        let b = MemoryPhraseExtractor.phraseHash(phrase, salt: Data(repeating: 0x43, count: 32))
        XCTAssertNotEqual(a, b)
    }
}
