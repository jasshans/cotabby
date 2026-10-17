import XCTest
@testable import Ghostype

final class PromptSectionPinTests: XCTestCase {
    func test_holdsTheFirstNonEmptyValueForASession() {
        var pin = PromptSectionPin()
        XCTAssertEqual(pin.resolve(session: "a") { [] }, [])
        XCTAssertEqual(pin.resolve(session: "a") { ["kind regards"] }, ["kind regards"])
        // Typing re-picks different examples; the prompt keeps the pinned ones.
        XCTAssertEqual(pin.resolve(session: "a") { ["see you soon"] }, ["kind regards"])
    }

    func test_newSessionRecomputes() {
        var pin = PromptSectionPin()
        _ = pin.resolve(session: "a") { ["kind regards"] }
        XCTAssertEqual(pin.resolve(session: "b") { ["cheers"] }, ["cheers"])
    }
}
