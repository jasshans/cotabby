import AppKit
import Foundation

/// File overview:
/// Recovers the exact caret x for a web host from typography instead of from the rounded box
/// Accessibility reports.
///
/// WebKit answers `AXBoundsForRange` with pixel-enclosing rects: a caret whose true position is
/// 481.1 comes back as the 482…484 box, and the trailing edge of the previous character is rounded
/// up as well. Measured in Safari, the ghost then started a full point right of where the host put
/// the accepted text. The host did tell us its exact font, though, and the visual line's left edge
/// (also from AX, but CSS boxes sit on whole pixels far more often than glyph edges do). The caret is
/// simply that edge plus the advance of the text on the line, shaped with the same font the host
/// used. The result is only trusted when it lands within a small distance of the reported caret,
/// which is what rules out soft-wrapped paragraphs, where the paragraph text is longer than the
/// visual line.
enum GhostCaretRefinement {
    /// Largest disagreement with the reported caret still attributable to rounding.
    static let maximumAdjustment: CGFloat = 1.5
    /// When the text advance stays under this fraction of the line width, the paragraph cannot
    /// have soft-wrapped, so a large disagreement means the reported caret is wrong (stale or
    /// mismeasured), not that the text spans multiple visual lines.
    static let noWrapFraction: CGFloat = 0.9

    struct Input {
        /// Left edge of the host's visual line box, in the same coordinates as `reportedCaretX`.
        let lineLeft: CGFloat
        /// Width of the host's visual line box. Used to rule out soft-wrapping when the
        /// typographic caret disagrees with the reported one beyond rounding.
        let lineWidth: CGFloat
        /// Text between the last hard line break and the caret.
        let paragraphTextBeforeCaret: String
        /// The host's exact typeface at its exact size.
        let font: NSFont
        let reportedCaretX: CGFloat
        let isRightToLeft: Bool
    }

    /// The refined caret x, or nil when the line is wrapped, empty, right-to-left, or the
    /// typographic answer cannot be trusted.
    ///
    /// Two cases return a value:
    /// - The typographic x lands within `maximumAdjustment` of the reported x: rounding fix.
    /// - The typographic x disagrees beyond rounding, but the text advance fits well inside the
    ///   line width, ruling out a soft wrap: the reported caret is stale or mismeasured, so the
    ///   typographic position (which must be right for unwrapped text in the host's own font)
    ///   wins. Without this, a wrong AX caret paints the ghost over the user's typed text.
    static func caretX(_ input: Input) -> CGFloat? {
        guard !input.isRightToLeft, !input.paragraphTextBeforeCaret.isEmpty, input.lineWidth > 0 else { return nil }
        let attributed = NSAttributedString(string: input.paragraphTextBeforeCaret, attributes: [.font: input.font])
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard advance > 0 else { return nil }
        let refined = input.lineLeft + advance
        let disagreement = abs(refined - input.reportedCaretX)
        guard disagreement <= maximumAdjustment
                || advance < input.lineWidth * noWrapFraction
        else { return nil }
        return refined
    }

    /// The paragraph text before the caret: everything after the last hard line break.
    static func paragraphTextBeforeCaret(in precedingText: String) -> String {
        if let breakIndex = precedingText.lastIndex(where: { $0.isNewline }) {
            return String(precedingText[precedingText.index(after: breakIndex)...])
        }
        return precedingText
    }
}
