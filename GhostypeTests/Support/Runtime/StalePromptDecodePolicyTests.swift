import XCTest
@testable import Ghostype

/// A superseded decode is kept when the next prompt extends it (ordinary typing) and aborted when
/// the next prompt diverges early, where its KV cache would not be reused.
final class StalePromptDecodePolicyTests: XCTestCase {
    func test_typingOnKeepsTheRunningDecode() {
        let running = String(repeating: "context ", count: 50) + "I'll send yo"
        XCTAssertFalse(StalePromptDecodePolicy.shouldAbort(running: running, next: running + "u"))
        XCTAssertFalse(StalePromptDecodePolicy.shouldAbort(running: running, next: String(running.dropLast(3)) + "the"))
    }

    func test_earlyDivergenceAbortsTheRunningDecode() {
        let running = "Dear Anna, " + String(repeating: "context ", count: 50)
        XCTAssertTrue(StalePromptDecodePolicy.shouldAbort(running: running, next: "Dear Ana, " + String(repeating: "context ", count: 50)))
        XCTAssertTrue(StalePromptDecodePolicy.shouldAbort(running: running, next: "something else entirely"))
    }

    func test_nothingRunningNeverAborts() {
        XCTAssertFalse(StalePromptDecodePolicy.shouldAbort(running: "", next: "anything"))
    }
}
