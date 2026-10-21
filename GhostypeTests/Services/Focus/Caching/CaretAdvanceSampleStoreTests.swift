import XCTest
@testable import Ghostype

@MainActor
final class CaretAdvanceSampleStoreTests: XCTestCase {
    func testNewSessionOnSameElementStartsWithoutPreviousWidthSample() {
        let store = CaretAdvanceSampleStore()
        var text = "as"
        var x: CGFloat = 100
        func observe(_ key: String) -> CaretAdvanceSampler.Sample? {
            store.sample(forKey: key, observation: .init(caretX: x, lineY: 100,
                documentCaret: text.count, precedingText: text, isPositioned: true))
        }
        _ = observe("123:recycled:1")
        for character in "the user writes" {
            text.append(character)
            x += 7.5
            _ = observe("123:recycled:1")
        }
        XCTAssertNotNil(observe("123:recycled:1"))
        XCTAssertNil(observe("123:recycled:2"))
    }
}
