import XCTest
@testable import Ghostype

final class PersonalDictionaryTests: XCTestCase {
    func testParsesCommasAndLinesTrimsAndDedupesCaseInsensitively() {
        XCTAssertEqual(PersonalDictionary.terms(from: " Ghostype, Secret Escapes\nMARI\n\n,ghostype "),
                       ["Ghostype", "Secret Escapes", "MARI"])
    }

    func testContainsIgnoresCase() {
        let terms = ["Ghostype", "MARI"]
        XCTAssertTrue(PersonalDictionary.contains("ghostype", in: terms))
        XCTAssertTrue(PersonalDictionary.contains("Mari", in: terms))
        XCTAssertFalse(PersonalDictionary.contains("Ghost", in: terms))
    }

    func testCapsTheNumberOfTerms() {
        let raw = (0..<300).map { "term\($0)" }.joined(separator: ",")
        XCTAssertEqual(PersonalDictionary.terms(from: raw).count, PersonalDictionary.maximumTerms)
    }
}
