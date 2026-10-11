import XCTest
@testable import Ghostype

/// Tests for the personal n-gram engine: the "fast" layer that predicts in microseconds
/// from the user's own typing patterns, with the LLM as background refinement.
final class PersonalNGramEngineTests: XCTestCase {
    func test_trigramPredictsNextWord() {
        let texts = [
            "looking forward to hearing from you",
            "looking forward to hearing from you",
            "looking forward to seeing you",
        ]
        let engine = PersonalNGramEngine.build(from: texts)

        // "looking forward" -> "to" (appears 3 times)
        XCTAssertEqual(engine.predictNext(after: "looking", "forward"), "to")
        // "forward to" -> "hearing" (2x) beats "seeing" (1x)
        XCTAssertEqual(engine.predictNext(after: "forward", "to"), "hearing")
    }

    func test_trigramRequiresMinimumCount() {
        // Single occurrence should not be trusted (minTrigramCount = 2).
        let texts = ["hello world foo"]
        let engine = PersonalNGramEngine.build(from: texts)
        XCTAssertNil(engine.predictNext(after: "hello", "world"))
    }

    func test_prefixCompletesWord() {
        let texts = [
            "hello world",
            "hello there",
            "hello again",
            "help me",
        ]
        let engine = PersonalNGramEngine.build(from: texts)

        // "hel" -> "hello" (3x) beats "help" (1x)... but "help" only appears once,
        // so it's filtered by minWordCount=3. "hello" appears 3 times.
        XCTAssertEqual(engine.completeWord(prefix: "hel"), "hello")
    }

    func test_predictMidWordReturnsRemainder() {
        let texts = [
            "hello world",
            "hello world",
            "hello world",
        ]
        let engine = PersonalNGramEngine.build(from: texts)

        // Typing "hel", should predict "lo" (remainder of "hello").
        XCTAssertEqual(engine.predict(for: "hel"), "lo")
    }

    func test_predictAtWordBoundaryReturnsNextWord() {
        let texts = [
            "looking forward to hearing",
            "looking forward to hearing",
        ]
        let engine = PersonalNGramEngine.build(from: texts)

        // At word boundary after "looking forward", predict " to".
        XCTAssertEqual(engine.predict(for: "looking forward "), " to")
    }

    func test_predictReturnsNilForUnknown() {
        let texts = ["hello world"]
        let engine = PersonalNGramEngine.build(from: texts)

        XCTAssertNil(engine.predict(for: "xyzzy "))
        XCTAssertNil(engine.predict(for: "q"))
    }

    func test_predictIsCaseInsensitive() {
        let texts = [
            "Hello World",
            "Hello World",
            "Hello World",
        ]
        let engine = PersonalNGramEngine.build(from: texts)

        XCTAssertEqual(engine.predict(for: "HEL"), "lo")
    }

    func test_emptyInputReturnsNil() {
        let engine = PersonalNGramEngine.build(from: [])
        XCTAssertNil(engine.predict(for: ""))
        XCTAssertNil(engine.predict(for: "   "))
    }
}

extension PersonalNGramEngineTests {
    func test_bigramFallbackFiresWhenTrigramMisses() {
        // "to" -> "hearing" seen twice as a bigram, but never after "forward".
        let texts = [
            "looking forward to hearing from you",
            "looking forward to hearing from you",
            "happy to hearing your thoughts",
            "happy to hearing your thoughts",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // Trigram ("xyz", "to") was never seen; bigram ("to" -> "hearing") fires.
        XCTAssertEqual(engine.predictNextWord(after: "xyz", "to"), "hearing")
    }

    func test_trigramBeatsBigramWhenBothFire() {
        let texts = [
            "looking forward to seeing you",
            "looking forward to seeing you",
            "thanks to hearing from you",
            "thanks to hearing from you",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // Trigram ("forward","to") -> "seeing" wins over bigram ("to" -> "hearing").
        XCTAssertEqual(engine.predictNextWord(after: "forward", "to"), "seeing")
    }

    func test_predictChainBuildsWholeSentence() {
        let texts = [
            "looking forward to hearing from you",
            "looking forward to hearing from you",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        XCTAssertEqual(
            engine.predictChain(for: "looking forward "),
            " to hearing from you"
        )
    }

    func test_predictChainFromMidWord() {
        let texts = [
            "hello world today",
            "hello world today",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // "hel" -> completes to "hello" ("lo"), then chains "world today".
        XCTAssertEqual(engine.predictChain(for: "hel"), "lo world today")
    }

    func test_predictChainStopsAtUnknown() {
        let texts = [
            "looking forward to hearing",
            "looking forward to hearing",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // Chain stops after "hearing": nothing follows it in history.
        XCTAssertEqual(engine.predictChain(for: "looking forward "), " to hearing")
    }

    func test_predictChainDoesNotLoop() {
        let texts = [
            "a b a b a b",
            "a b a b a b",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // "a b" -> "a" -> "b" -> "a"... the visited-set terminates the cycle.
        XCTAssertEqual(engine.predictChain(for: "a b "), " a b")
    }

    func test_predictChainDegenerateRepetitionReturnsNil() {
        let texts = [
            "the the the the",
            "the the the the",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        // Predicting "the" after "the the" is useless; fall through to the LLM.
        XCTAssertNil(engine.predictChain(for: "the the "))
    }

    func test_predictChainRespectsMaxWords() {
        let texts = [
            "a b c d e f g h i j k l m n o p",
            "a b c d e f g h i j k l m n o p",
        ]
        let engine = PersonalNGramEngine.build(from: texts)
        let chain = engine.predictChain(for: "a b ", maxWords: 3)
        XCTAssertEqual(chain, " c d e")
    }
}
