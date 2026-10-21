import CoreGraphics
import Foundation

/// File overview:
/// Where Ghostype's field icon stands and when it shows. The icon marks the line being completed:
/// it sits just left of where that line starts, centred on it, and stays up for as long as Ghostype
/// is completing in the field.
///
/// Both rules used to live inside `ActivationIndicatorController` and follow every focus poll as
/// is. The icon was placed left of the field's frame, which `FocusSnapshotResolver` widens to at
/// least 500pt (or a parent container), so it could stand well left of the text; and any one poll
/// that read the field as unsupported hid it, which Chrome produces routinely while its text
/// updates (2026-10-21, test pages: "Missing text value" reads between supported ones), so the icon
/// blinked away while a suggestion was on screen. Pure, so both rules are tested on their own.
nonisolated enum FieldIndicatorPlacement {
    /// A line the icon marks: where its text starts and its vertical centre, in global Cocoa points.
    struct LineAnchor: Equatable, Sendable {
        let left: CGFloat
        let midY: CGFloat
    }

    /// Space between the icon and the line's first character.
    static let gap: CGFloat = 4
    static let screenInset: CGFloat = 2

    /// The icon's origin for `line`: its right edge `gap` left of the line's start, centred on the
    /// line, kept inside `visibleFrame` when one is known.
    static func origin(for line: LineAnchor, size: CGSize, visibleFrame: CGRect?) -> CGPoint {
        var originX = line.left - gap - size.width
        var originY = line.midY - size.height / 2
        if let frame = visibleFrame {
            originX = min(max(originX, frame.minX + screenInset), frame.maxX - size.width - screenInset)
            originY = min(max(originY, frame.minY + screenInset), frame.maxY - size.height - screenInset)
        }
        return CGPoint(x: originX, y: originY)
    }

    /// The caret's line as a focus poll describes it: the host's own line box when it reported one,
    /// else the run-measured content edge, else the field's own frame (the unwidened element frame
    /// when there is one). An estimated caret is a field-sized guess, so a reported line box gives
    /// the height then.
    static func lineAnchor(
        caretRect: CGRect,
        caretIsEstimated: Bool,
        hostLineRect: CGRect?,
        contentLeft: CGFloat?,
        fieldFrame: CGRect?
    ) -> LineAnchor? {
        guard let left = hostLineRect?.minX ?? contentLeft ?? fieldFrame?.minX
            ?? (caretRect.isEmpty ? nil : caretRect.minX) else { return nil }
        let midY: CGFloat
        if let line = hostLineRect, caretIsEstimated || caretRect.isEmpty {
            midY = line.midY
        } else if !caretRect.isEmpty {
            midY = caretRect.midY
        } else {
            return nil
        }
        return LineAnchor(left: left, midY: midY)
    }
}

/// Whether the field icon shows, from the focus polls and the suggestion on screen.
///
/// Shows while the focused field is supported. A poll that reads the same app's field as not
/// supported keeps the icon for `grace` after the last supported read, and for as long as a
/// suggestion is on screen; a different app, or Ghostype off for this field, hides it at once.
nonisolated struct FieldIndicatorVisibility {
    enum Decision: Equatable {
        case show
        /// Keep what is on screen; decide again at `until` if nothing changes before then.
        case hold(until: TimeInterval)
        case hide
    }

    /// Longer than the transient unsupported reads seen in Chrome (one or two ~150 ms polls), short
    /// enough that leaving a field is not noticeably late.
    static let grace: TimeInterval = 0.6

    private var lastSupported: (bundleIdentifier: String?, time: TimeInterval)?

    mutating func decide(
        isEnabled: Bool,
        isSupported: Bool,
        bundleIdentifier: String?,
        suggestionVisible: Bool,
        time: TimeInterval
    ) -> Decision {
        guard isEnabled else {
            lastSupported = nil
            return .hide
        }
        if isSupported {
            lastSupported = (bundleIdentifier, time)
            return .show
        }
        guard let last = lastSupported, last.bundleIdentifier == bundleIdentifier else {
            lastSupported = nil
            return .hide
        }
        if suggestionVisible {
            return .hold(until: time + Self.grace)
        }
        let until = last.time + Self.grace
        return time < until ? .hold(until: until) : .hide
    }
}
