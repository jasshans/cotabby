import XCTest
@testable import Ghostype

/// Typing into the captured window must not count as new screen content (it threw away the
/// visible suggestion and the KV-cached prompt every capture); navigating to new content must.
final class ScreenExcerptChangePolicyTests: XCTestCase {
    private let chat = (1...12).map { "Message \($0) about the quarterly plan" }.joined(separator: "\n")

    func test_typingOneLineIsNotMaterial() {
        let typed = chat + "\nI think we should send the upd"
        XCTAssertFalse(ScreenExcerptChangePolicy.isMaterialChange(from: chat, to: typed))
        XCTAssertFalse(ScreenExcerptChangePolicy.isMaterialChange(from: typed, to: typed + "ated plan"))
    }

    func test_differentContentIsMaterial() {
        let other = (1...12).map { "Line \($0) of a different document" }.joined(separator: "\n")
        XCTAssertTrue(ScreenExcerptChangePolicy.isMaterialChange(from: chat, to: other))
    }

    func test_firstCaptureIsMaterial() {
        XCTAssertTrue(ScreenExcerptChangePolicy.isMaterialChange(from: nil, to: chat))
        XCTAssertTrue(ScreenExcerptChangePolicy.isMaterialChange(from: "", to: chat))
    }
}
