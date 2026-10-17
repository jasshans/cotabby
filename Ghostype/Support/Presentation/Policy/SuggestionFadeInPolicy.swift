import Foundation

/// Decides whether a freshly shown ghost-text overlay should fade in rather than appear instantly.
///
/// The hard rule this protects: a fade may only play on a *genuine appearance* of the overlay, never
/// on an update to one that is already on screen. Caret repositions, streamed-token extensions, and
/// word-by-word advances all re-invoke the show path while the panel stays visible; restarting the
/// opacity animation on any of those would make stable ghost text flicker on every keystroke. The
/// `overlayWasVisible` input is the panel state captured *before* the new content is applied, so a
/// `false` value means the panel was hidden and this is a real first paint.
///
/// `reduceMotionEnabled` mirrors the system Accessibility "Reduce Motion" preference. Honoring it
/// suppresses the animation even when the user has the Ghostype toggle on, because non-essential
/// motion is exactly what that setting asks apps to drop; the suggestion still appears, just without
/// the fade. Keeping the decision in a pure function lets all three inputs be exhaustively tested
/// without standing up an `NSPanel` or AppKit animation.
enum SuggestionFadeInPolicy {
    static func shouldFadeIn(
        isEnabled: Bool,
        overlayWasVisible: Bool,
        reduceMotionEnabled: Bool
    ) -> Bool {
        guard isEnabled, !reduceMotionEnabled else {
            return false
        }
        return !overlayWasVisible
    }
}

/// File overview:
/// Pure rules for the type-on reveal of inline ghost text.
///
/// Why this exists: a completion used to land on screen as one block the moment it arrived, so a
/// six-word phrase hit the eye all at once ("as if someone hit you"). Revealing it left to right at
/// a fast typing cadence reads as the text being written at the caret instead. The reveal is purely
/// visual: the coordinator's session (and therefore Tab acceptance) always holds the full text.
///
/// `OverlayController` owns the clock; this type only answers "how far should the reveal start"
/// for a new presentation and "how far should it be after `elapsed` seconds", in UTF-16 offsets
/// into the presented text (the unit `GhostTextLayout.Row.utf16Range` uses).
enum GhostRevealPolicy {
    /// Characters per second while revealing. ~120 cps is a brisk typist, fast enough that a
    /// short phrase never feels like it lags the caret, slow enough for the eye to read it as motion.
    static let charactersPerSecond: Double = 120
    /// Upper bound on one reveal. A long tail speeds up instead of trickling in.
    static let maximumDuration: TimeInterval = 0.22

    /// How much of `newText` is already on screen and must not be re-revealed.
    ///
    /// The overlay currently shows `previousText[previousConsumed..<previousRevealed]` (UTF-16).
    /// If the new text starts with exactly those characters (a streamed partial growing, or a
    /// re-present after type-through), they stay put and the reveal resumes after them. Anything
    /// else is a different suggestion and reveals from zero.
    static func carriedOverUTF16(
        previousText: String?,
        previousConsumed: Int,
        previousRevealed: Int,
        newText: String
    ) -> Int {
        guard let previousText else { return 0 }
        let previous = previousText as NSString
        let start = min(max(previousConsumed, 0), previous.length)
        let end = min(max(previousRevealed, start), previous.length)
        guard end > start else { return 0 }
        let shown = previous.substring(with: NSRange(location: start, length: end - start))
        return newText.hasPrefix(shown) ? (shown as NSString).length : 0
    }

    /// Revealed UTF-16 count `elapsed` seconds after a reveal of `text` started at `startUTF16`,
    /// snapped back to a composed-character boundary so an emoji or accented letter never draws half.
    static func revealedUTF16(text: String, startUTF16: Int, elapsed: TimeInterval) -> Int {
        let ns = text as NSString
        let total = ns.length
        let start = min(max(startUTF16, 0), total)
        guard start < total, elapsed > 0 else { return start }
        let remaining = Double(total - start)
        let rate = max(charactersPerSecond, remaining / maximumDuration)
        let target = start + Int((elapsed * rate).rounded(.up))
        guard target < total else { return total }
        let snapped = ns.rangeOfComposedCharacterSequence(at: target).location
        return max(snapped, start)
    }
}
