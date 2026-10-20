import XCTest
@testable import Ghostype

final class GhostAnchorTrustPolicyTests: XCTestCase {
    func testAddressBarWithoutReportedFontRequiresFreshCaret() {
        XCTAssertTrue(GhostAnchorTrustPolicy.requiresFreshCaret(isSingleLineField: true, hostNamesFace: false))
    }

    func testNamedFontSingleLineFieldKeepsMeasuredAdvancePath() {
        XCTAssertFalse(GhostAnchorTrustPolicy.requiresFreshCaret(isSingleLineField: true, hostNamesFace: true))
    }

    func testParagraphPreservesExistingPlacementPath() {
        XCTAssertFalse(GhostAnchorTrustPolicy.requiresFreshCaret(isSingleLineField: false, hostNamesFace: false))
    }
}