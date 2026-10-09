import AppKit
import XCTest
@testable import Ghostype

final class GhostCaretRefinementTests: XCTestCase {
    private let helvetica = NSFont(name: "Helvetica", size: 16)!

    /// Safari, Helvetica 16px input: content edge 265, text "Field two alpha bravo charlie x" advances
    /// 216.1pt, AX reported the caret at 482. The refined caret lands on the true 481.1.
    func testRefinesARoundedWebCaretFromTheLineEdgeAndTextAdvance() {
        let text = "Field two alpha bravo charlie x"
        let advance = (text as NSString).size(withAttributes: [.font: helvetica]).width
        let refined = GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, lineWidth: 500, paragraphTextBeforeCaret: text, font: helvetica, reportedCaretX: 482, isRightToLeft: false)
        )
        XCTAssertEqual(refined ?? -1, 265 + advance, accuracy: 0.001)
        XCTAssertEqual(refined ?? -1, 481.1, accuracy: 0.6)
    }

    func testDisagreementBeyondRoundingIsRejected() {
        // A soft-wrapped paragraph: the paragraph text is far longer than the visual line.
        let wrapped = String(repeating: "alpha bravo charlie ", count: 6) + "x"
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, lineWidth: 500, paragraphTextBeforeCaret: wrapped, font: helvetica, reportedCaretX: 482, isRightToLeft: false)
        ))
    }

    func testLargeDisagreementWithoutWrapUsesTypographicCaret() {
        // The reported caret is far from the typographic position, but the text fits well
        // inside the line, so the paragraph cannot have wrapped: the AX caret is stale or
        // mismeasured, and the typographic position wins. Without this, the ghost would be
        // painted over the user's typed text.
        let text = "hello"
        let advance = (text as NSString).size(withAttributes: [.font: helvetica]).width
        let refined = GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 100, lineWidth: 500, paragraphTextBeforeCaret: text, font: helvetica, reportedCaretX: 110, isRightToLeft: false)
        )
        XCTAssertEqual(refined ?? -1, 100 + advance, accuracy: 0.001)
    }

    func testEmptyLineAndRightToLeftAreLeftToTheHost() {
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, lineWidth: 500, paragraphTextBeforeCaret: "", font: helvetica, reportedCaretX: 265, isRightToLeft: false)
        ))
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, lineWidth: 500, paragraphTextBeforeCaret: "abc", font: helvetica, reportedCaretX: 290, isRightToLeft: true)
        ))
    }

    func testParagraphTextStopsAtTheLastHardBreak() {
        XCTAssertEqual(GhostCaretRefinement.paragraphTextBeforeCaret(in: "first line\nsecond x"), "second x")
        XCTAssertEqual(GhostCaretRefinement.paragraphTextBeforeCaret(in: "no breaks"), "no breaks")
    }
}
