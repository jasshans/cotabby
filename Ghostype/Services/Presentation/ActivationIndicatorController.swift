import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks the line Ghostype is completing with its icon,
/// just left of where that line starts. Placement and visibility rules live in
/// `FieldIndicatorPlacement` and `FieldIndicatorVisibility`; this controller feeds them the focus
/// polls (from `AppDelegate`) and the suggestion on screen (from `OverlayController`).
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    private lazy var contentView: NSHostingView<AnyView> = {
        NSHostingView(rootView: AnyView(EmptyView()))
    }()

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }()

    private var isVisible = false
    /// The chip's measured size, cached after the first layout: the view is fixed-size, so
    /// repeat placements can compute the frame (and hit the early-out) without re-measuring.
    private var cachedContentSize: CGSize?

    /// The latest focus poll's facts, kept so a recheck or a suggestion change decides again.
    private var isEnabled = false
    private var isSupported = false
    private var bundleIdentifier: String?
    private var focusLine: FieldIndicatorPlacement.LineAnchor?
    /// The line of the suggestion on screen (from `OverlayController`), nil when none is.
    private var presentedLine: FieldIndicatorPlacement.LineAnchor?
    private var visibility = FieldIndicatorVisibility()
    private var recheck: DispatchWorkItem?

    /// One focus poll: whether the icon may show at all (Ghostype on for this field, indicator
    /// enabled), whether the field is supported, and the caret's line. A poll without a line (an
    /// unsupported read) keeps the last one for the same app, so a held icon does not move.
    func update(
        isEnabled: Bool,
        isSupported: Bool,
        bundleIdentifier: String?,
        line: FieldIndicatorPlacement.LineAnchor?
    ) {
        if let line {
            focusLine = line
        } else if bundleIdentifier != self.bundleIdentifier {
            focusLine = nil
        }
        self.isEnabled = isEnabled
        self.isSupported = isSupported
        self.bundleIdentifier = bundleIdentifier
        decide()
    }

    /// The suggestion on screen moved to `line`, or went away (nil). While one is visible the icon
    /// marks its line, which the overlay knows exactly even where the focus poll only estimates
    /// the caret (a Chromium contenteditable).
    func followPresentedLine(_ line: FieldIndicatorPlacement.LineAnchor?) {
        presentedLine = line
        decide()
    }

    /// Hides the indicator now (app termination); the next focus poll decides again.
    func hide(reason _: String) {
        recheck?.cancel()
        panel.orderOut(nil)
        isVisible = false
    }

    private func decide() {
        recheck?.cancel()
        recheck = nil
        let decision = visibility.decide(
            isEnabled: isEnabled,
            isSupported: isSupported,
            bundleIdentifier: bundleIdentifier,
            suggestionVisible: presentedLine != nil,
            time: ProcessInfo.processInfo.systemUptime
        )
        switch decision {
        case .show:
            place(at: presentedLine ?? focusLine)
        case let .hold(until):
            // Keep what is on screen; a held icon still follows the suggestion's line.
            if isVisible, let presentedLine {
                place(at: presentedLine)
            }
            let work = DispatchWorkItem { [weak self] in self?.decide() }
            recheck = work
            let delay = max(until - ProcessInfo.processInfo.systemUptime, 0.01)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .hide:
            panel.orderOut(nil)
            isVisible = false
        }
    }

    private func place(at line: FieldIndicatorPlacement.LineAnchor?) {
        // No line known yet (a first poll without geometry): leave the icon where it is.
        guard let line else { return }
        let size: CGSize
        if let cachedContentSize {
            size = cachedContentSize
        } else {
            contentView.rootView = AnyView(FieldEdgeIconIndicatorView())
            contentView.layoutSubtreeIfNeeded()
            size = contentView.fittingSize
            cachedContentSize = size
        }
        let lineStart = CGRect(x: line.left, y: line.midY, width: 0, height: 0)
        let origin = FieldIndicatorPlacement.origin(for: line, size: size, visibleFrame: screen(for: lineStart)?.visibleFrame)
        let frame = CGRect(origin: origin, size: size).integral
        if isVisible, panel.frame == frame, panel.isVisible {
            return
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Chooses the screen that currently contains the given rect's center point.
    private func screen(for rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingScreen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(midpoint)
        }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(rect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
