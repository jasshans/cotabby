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
