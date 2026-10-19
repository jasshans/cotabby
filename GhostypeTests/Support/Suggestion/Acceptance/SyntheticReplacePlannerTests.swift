import XCTest
@testable import Ghostype

/// Tests for the pure synthetic-key accounting behind `SuggestionInserter.replace`.
///
/// The accounting is what keeps the picker's own deletes from leaking back as user input: the
/// suppression window must cover exactly the keydowns we post. A single emoji is one keydown even
/// though it is two UTF-16 units (a surrogate pair), which is the subtle case these tests pin down.
final class SyntheticReplacePlannerTests: XCTestCase {

    func test_plan_countsBackspacesAndOneInsertKeyDown() {
        let plan = SyntheticReplacePlanner.plan(deletingCharacterCount: 6, text: "😀")

        XCTAssertEqual(plan.backspaceCount, 6)
        XCTAssertEqual(plan.insertUTF16, Array("😀".utf16))
        XCTAssertEqual(plan.insertUTF16.count, 2, "An emoji glyph is a surrogate pair, i.e. two UTF-16 units")
        XCTAssertEqual(plan.totalKeyDownCount, 7, "Six deletes plus one insertion keydown")
        XCTAssertFalse(plan.isNoop)
    }

    func test_plan_emptyInsertCountsNoInsertionKeyDown() {
        let plan = SyntheticReplacePlanner.plan(deletingCharacterCount: 3, text: "")

        XCTAssertEqual(plan.backspaceCount, 3)
        XCTAssertTrue(plan.insertUTF16.isEmpty)
        XCTAssertEqual(plan.totalKeyDownCount, 3)
        XCTAssertFalse(plan.isNoop)
    }

    func test_plan_negativeDeleteCountClampsToZero() {
        let plan = SyntheticReplacePlanner.plan(deletingCharacterCount: -5, text: "x")

        XCTAssertEqual(plan.backspaceCount, 0)
        XCTAssertEqual(plan.totalKeyDownCount, 1)
    }

    func test_plan_noopWhenNothingToDeleteOrInsert() {
        let plan = SyntheticReplacePlanner.plan(deletingCharacterCount: 0, text: "")

        XCTAssertTrue(plan.isNoop)
        XCTAssertEqual(plan.totalKeyDownCount, 0)
    }

    func test_plan_stripsCarriageReturns() {
        let plan = SyntheticReplacePlanner.plan(deletingCharacterCount: 1, text: "a\rb")

        XCTAssertEqual(plan.insertUTF16, Array("ab".utf16))
    }

    /// One backspace deletes one character, so an Accessibility (UTF-16) length must be converted:
    /// an emoji or a letter with a combining accent is several units but one press.
    func test_characterCount_convertsTrailingUTF16LengthsToBackspaces() {
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 4, in: "hi :abc"), 4)
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 4, in: "ok 😀ab"), 3)
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 5, in: "cafe\u{301} "), 4)
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 3, in: "cafe\u{301} "), 2)
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 0, in: "abc"), 0)
        XCTAssertEqual(SyntheticReplacePlanner.characterCount(ofTrailingUTF16: 5, in: "abc"), 5)
    }
}
