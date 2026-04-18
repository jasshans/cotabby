import AppKit
import SwiftUI

/// File overview:
/// Owns the first-run welcome experience. This type persists whether onboarding has already been
/// shown and manages the one compact AppKit window that hosts the SwiftUI welcome wizard.
///
/// We keep this in `App/` instead of `UI/` because it owns lifecycle and persistence, not just
/// rendering. In React terms, this is a tiny controller/store plus a window host.
@MainActor
final class WelcomeCoordinator: NSObject, NSWindowDelegate {
    private enum Layout {
        /// Match the first welcome step so the window does not flash at an oversized default before
        /// SwiftUI has a chance to report its preferred content size.
        static let initialContentSize = NSSize(width: 500, height: 320)
    }

    private let permissionManager: PermissionManager
    private let permissionGuidanceController: PermissionGuidanceController
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let userDefaults: UserDefaults

    private var welcomeWindowController: NSWindowController?

    private static let hasShownWelcomeDefaultsKey = "hasShownWelcomeWindow"

    init(
        permissionManager: PermissionManager,
        permissionGuidanceController: PermissionGuidanceController,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        userDefaults: UserDefaults = .standard
    ) {
        self.permissionManager = permissionManager
        self.permissionGuidanceController = permissionGuidanceController
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.userDefaults = userDefaults
    }

    /// Presents the welcome UI once for the lifetime of this installation.
    /// The "shown" bit is persisted at presentation time so first-run onboarding stays one-time
    /// even if the user simply closes the window instead of pressing the button.
    func presentIfNeeded() {
        guard !userDefaults.bool(forKey: Self.hasShownWelcomeDefaultsKey) else {
            return
        }

        userDefaults.set(true, forKey: Self.hasShownWelcomeDefaultsKey)
        showWelcome()
    }

    /// Manual entry point for reopening the welcome screen later from the menu.
    func showWelcome() {
        if let window = welcomeWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: WelcomeView(
                permissionManager: permissionManager,
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager,
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                permissionGuidanceController: permissionGuidanceController,
                onPreferredWindowSizeChange: { [weak self] size in
                    self?.resizeWelcomeWindow(to: size)
                },
                onDismiss: { [weak self] in
                    self?.dismissWelcome()
                }
            )
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Layout.initialContentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to tabby"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        welcomeWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        if closingWindow == welcomeWindowController?.window {
            permissionGuidanceController.dismiss()
            welcomeWindowController = nil
        }
    }

    private func dismissWelcome() {
        permissionGuidanceController.dismiss()
        welcomeWindowController?.close()
    }

    /// Window sizing is an AppKit responsibility, so the SwiftUI onboarding view reports its
    /// preferred content size upward and the coordinator applies it here.
    ///
    /// We keep the window centered while resizing because onboarding is a modal-like flow; letting
    /// the frame grow down and to the right makes it feel jumpy and accidental.
    private func resizeWelcomeWindow(to contentSize: NSSize) {
        guard let window = welcomeWindowController?.window else {
            return
        }

        let currentContentSize = window.contentLayoutRect.size
        guard abs(currentContentSize.width - contentSize.width) > 0.5
            || abs(currentContentSize.height - contentSize.height) > 0.5 else {
            return
        }

        let targetWindowFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let currentFrame = window.frame
        let centeredOrigin = NSPoint(
            x: currentFrame.midX - (targetWindowFrame.width / 2),
            y: currentFrame.midY - (targetWindowFrame.height / 2)
        )
        let centeredFrame = NSRect(origin: centeredOrigin, size: targetWindowFrame.size).integral

        window.setFrame(centeredFrame, display: true, animate: true)
    }
}
