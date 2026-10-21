import XCTest
@testable import Ghostype

/// The field icon stands just left of the completed line's start, centred on it, and stays up while
/// Ghostype is completing in the field: through transient unsupported reads and while a suggestion
/// is on screen, but not into another app or past Ghostype being off.
final class FieldIndicatorPolicyTests: XCTestCase {
    private typealias Placement = FieldIndicatorPlacement

    func testTheIconStandsJustLeftOfTheLinesStartCentredOnIt() {
        let origin = Placement.origin(for: .init(left: 120, midY: 500), size: CGSize(width: 14, height: 14), visibleFrame: nil)
        XCTAssertEqual(origin.x, 120 - Placement.gap - 14)
        XCTAssertEqual(origin.y, 493)
    }

    func testTheIconStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let origin = Placement.origin(for: .init(left: 6, midY: 500), size: CGSize(width: 14, height: 14), visibleFrame: screen)
        XCTAssertEqual(origin.x, Placement.screenInset)
    }

    func testTheLineStartsWhereTheHostsLineBoxDoesNotAtTheWidenedField() {
        let anchor = Placement.lineAnchor(
            caretRect: CGRect(x: 550, y: 1001, width: 2, height: 13),
            caretIsEstimated: false,
            hostLineRect: CGRect(x: 41, y: 1000, width: 300, height: 15),
            contentLeft: 44,
            fieldFrame: CGRect(x: 32, y: 945, width: 529, height: 65)
        )
        XCTAssertEqual(anchor, .init(left: 41, midY: 1007.5))
    }

    func testAnEstimatedCaretTakesItsHeightFromTheReportedLine() {
        let anchor = Placement.lineAnchor(
            caretRect: CGRect(x: 32, y: 945, width: 2, height: 65),
            caretIsEstimated: true,
            hostLineRect: CGRect(x: 41, y: 1000, width: 300, height: 14),
            contentLeft: nil, fieldFrame: nil
        )
        XCTAssertEqual(anchor, .init(left: 41, midY: 1007))
        let fieldOnly = Placement.lineAnchor(
            caretRect: CGRect(x: 60, y: 945, width: 2, height: 18), caretIsEstimated: false,
            hostLineRect: nil, contentLeft: nil, fieldFrame: CGRect(x: 32, y: 940, width: 529, height: 65)
        )
        XCTAssertEqual(fieldOnly, .init(left: 32, midY: 954))
    }

    func testTransientUnsupportedReadsKeepTheIcon() {
        var visibility = FieldIndicatorVisibility()
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: false, time: 10), .show)
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: false, bundleIdentifier: "chrome", suggestionVisible: false, time: 10.2),
                       .hold(until: 10 + FieldIndicatorVisibility.grace))
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: false, time: 10.3), .show)
        // A field that stays unsupported past the grace period loses the icon.
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: false, bundleIdentifier: "chrome", suggestionVisible: false, time: 11), .hide)
    }

    func testAVisibleSuggestionKeepsTheIcon() {
        var visibility = FieldIndicatorVisibility()
        _ = visibility.decide(isEnabled: true, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: true, time: 10)
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: false, bundleIdentifier: "chrome", suggestionVisible: true, time: 12),
                       .hold(until: 12 + FieldIndicatorVisibility.grace))
    }

    func testAnotherAppOrGhostypeOffHidesTheIconAtOnce() {
        var visibility = FieldIndicatorVisibility()
        _ = visibility.decide(isEnabled: true, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: true, time: 10)
        XCTAssertEqual(visibility.decide(isEnabled: true, isSupported: false, bundleIdentifier: "finder", suggestionVisible: false, time: 10.1), .hide)
        _ = visibility.decide(isEnabled: true, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: false, time: 11)
        XCTAssertEqual(visibility.decide(isEnabled: false, isSupported: true, bundleIdentifier: "chrome", suggestionVisible: true, time: 11.1), .hide)
    }
}
