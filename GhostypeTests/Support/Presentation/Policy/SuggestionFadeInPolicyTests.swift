import XCTest
@testable import Ghostype

/// Tests for the overlay fade-in gate: the fade plays only on a genuine appearance, and the user
/// toggle and the system Reduce Motion preference each veto it. These three inputs are exactly the
/// distinctions that, if wrong, would either flicker stable ghost text on every keystroke or animate
/// when the user asked for no motion.
final class SuggestionFadeInPolicyTests: XCTestCase {
    func test_fadesInOnlyOnAGenuineAppearanceWithTheToggleOnAndMotionAllowed() {
        // Every one of the eight combinations is listed so no single veto can silently stop
        // mattering. The reasons name which rule decides each row.
        let cases: [(enabled: Bool, wasVisible: Bool, reduceMotion: Bool, fades: Bool, reason: String)] = [
            (true, false, false, true, "first paint with the toggle on"),
            // A reposition / streamed extension / word-by-word advance re-enters the show path while
            // the panel stays on screen; restarting the ramp there is the flicker the gate prevents.
            (true, true, false, false, "update to an overlay already on screen"),
            // Reduce Motion is an accessibility need that overrides the cosmetic toggle.
            (true, false, true, false, "Reduce Motion vetoes the first paint"),
            (true, true, true, false, "Reduce Motion and already visible"),
            // Disabled wins regardless of visibility: the user opted into instant ghost text.
            (false, false, false, false, "toggle off on first paint"),
            (false, true, false, false, "toggle off while visible"),
            (false, false, true, false, "toggle off and Reduce Motion"),
            (false, true, true, false, "every veto at once")
        ]

        for row in cases {
            XCTAssertEqual(
                SuggestionFadeInPolicy.shouldFadeIn(
                    isEnabled: row.enabled,
                    overlayWasVisible: row.wasVisible,
                    reduceMotionEnabled: row.reduceMotion
                ),
                row.fades,
                row.reason
            )
        }
    }
}


/// The reveal must never re-type characters already on screen (that is the jump it exists to
/// remove), must always finish within its bound, and must never split a composed character.
final class GhostRevealPolicyTests: XCTestCase {
    func test_carriesOverTextAlreadyShownWhenTheNewTextExtendsIt() {
        // A streamed partial grew from "hello wor" to "hello world and".
        XCTAssertEqual(GhostRevealPolicy.carriedOverUTF16(
            previousText: "hello wor", previousConsumed: 0, previousRevealed: 9, newText: "hello world and"), 9)
        // After typing "he" through it, the re-present starts at the remaining text.
        XCTAssertEqual(GhostRevealPolicy.carriedOverUTF16(
            previousText: "hello world", previousConsumed: 2, previousRevealed: 7, newText: "llo world"), 5)
    }

    func test_revealsFromZeroForADifferentSuggestionOrNothingShown() {
        XCTAssertEqual(GhostRevealPolicy.carriedOverUTF16(
            previousText: "hello world", previousConsumed: 0, previousRevealed: 11, newText: "goodbye"), 0)
        XCTAssertEqual(GhostRevealPolicy.carriedOverUTF16(
            previousText: nil, previousConsumed: 0, previousRevealed: 0, newText: "hello"), 0)
    }

    func test_revealIsMonotonicAndFinishesWithinTheBound() {
        let text = String(repeating: "word ", count: 20)
        var last = 0
        for step in 0...30 {
            let value = GhostRevealPolicy.revealedUTF16(text: text, startUTF16: 0, elapsed: Double(step) * 0.01)
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
        XCTAssertEqual(GhostRevealPolicy.revealedUTF16(
            text: text, startUTF16: 0, elapsed: GhostRevealPolicy.maximumDuration), (text as NSString).length)
    }

    func test_neverSplitsAComposedCharacter() {
        let text = "ok 👍🏽 done"
        for step in 0...40 {
            let value = GhostRevealPolicy.revealedUTF16(text: text, startUTF16: 0, elapsed: Double(step) * 0.001)
            let ns = text as NSString
            if value < ns.length {
                XCTAssertEqual(ns.rangeOfComposedCharacterSequence(at: value).location, value)
            }
        }
    }
}
