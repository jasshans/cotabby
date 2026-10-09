import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Logging

/// File overview:
/// Polls and exposes the three system permissions Ghostype depends on: Accessibility for reading
/// focus state, Input Monitoring for global key capture, and Screen Recording for screenshot
/// context that improves autocomplete relevance.
///
/// `@MainActor` guarantees permission state is mutated on the UI thread.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var screenRecordingGranted = false

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Completes when the first permission read finishes. The three TCC queries are XPC
    /// round-trips to tccd, so the initial read happens off the main thread instead of on the
    /// launch critical path. Launch code that must decide on permission state (the
    /// permission-reminder check) awaits this rather than blocking on TCC.
    ///
    /// Lazily started on first access (always during launch, via AppDelegate): a `let`
    /// initialized in `init()` cannot capture `self` in its task body because the other
    /// stored properties aren't assigned yet at that point.
    lazy var initialRefresh: Task<Void, Never> = Task.detached { [weak self] in
        let state = Self.querySystemState()
        await MainActor.run { [weak self] in
            self?.applyRefresh(state)
        }
    }

    /// Keeps UI state aligned with permission changes the user makes in System Settings.
    ///
    /// A permission can only change while the user is in System Settings, i.e. while Ghostype is
    /// backgrounded; returning to the app fires `didBecomeActive`, and the menu/settings surfaces
    /// already call `refresh()` when they appear. So instead of a forever-running 2s poll (a 0.5 Hz
    /// main-thread wake for the whole session, long after every grant is already in place), we
    /// refresh on activation and keep the short catch-up poll alive ONLY while a required permission
    /// is still missing — the onboarding window where snappy feedback matters. Once the required set
    /// is granted the timer is torn down, so an established user pays zero idle wakeups here.
    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer closure is not formally actor-isolated even though `queue: .main`
            // guarantees main-thread delivery. `assumeIsolated` makes the hop explicit for strict
            // concurrency checking (and keeps the refresh synchronous with activation, so surfaces
            // reading permission state on this same turn see fresh values). Same pattern as
            // `SystemMetricsStore`'s main-queue timer.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // `refresh()` also (re)configures polling for the current grant state, so a process that
        // launches with every permission already granted never arms the timer at all. The first
        // read runs off the main thread (see `initialRefresh`); polling config rides along with
        // its completion.
        initialRefresh = Task.detached { [weak self] in
            let state = Self.querySystemState()
            await MainActor.run { [weak self] in
                self?.applyRefresh(state)
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Re-reads the current system permission state and republishes any changes to observers.
    /// Synchronous: used by the activation observer and surfaces where the caller is already on
    /// the main thread and wants fresh state now. Launch uses the async `initialRefresh` instead.
    func refresh() {
        applyRefresh(Self.querySystemState())
    }

    /// The three TCC queries. Read-only and thread-safe, so the launch path can run them off
    /// the main thread.
    private nonisolated static func querySystemState() -> (
        accessibility: Bool, inputMonitoring: Bool, screenRecording: Bool
    ) {
        (
            AXIsProcessTrusted(),
            CGPreflightListenEventAccess(),
            CGPreflightScreenCaptureAccess()
        )
    }

    /// Compares a queried state against the published one and republishes changes.
    private func applyRefresh(_ state: (accessibility: Bool, inputMonitoring: Bool, screenRecording: Bool)) {
        // `@Published` notifies on assignment, even when the value is unchanged. Compare first so
        // the 2-second poll does not redraw SwiftUI surfaces that already have the right state.
        if accessibilityGranted != state.accessibility {
            CotabbyLogger.app.info("Accessibility permission changed: \(state.accessibility)")
            accessibilityGranted = state.accessibility
        }

        if inputMonitoringGranted != state.inputMonitoring {
            CotabbyLogger.app.info("Input Monitoring permission changed: \(state.inputMonitoring)")
            inputMonitoringGranted = state.inputMonitoring
        }

        if screenRecordingGranted != state.screenRecording {
            CotabbyLogger.app.info("Screen Recording permission changed: \(state.screenRecording)")
            screenRecordingGranted = state.screenRecording
        }

        updatePollingForCurrentState()
    }

    /// Arms the 2-second catch-up poll only while a required permission is still missing, and stops
    /// it once the required set is granted. Permission changes after that are rare and deliberate,
    /// and every one is followed by the user returning to the app (`didBecomeActive`) or opening a
    /// Ghostype surface that already calls `refresh()`, so the standing timer buys nothing but idle
    /// main-thread wakeups.
    private func updatePollingForCurrentState() {
        if requiredPermissionsGranted {
            stopPolling()
        } else {
            startPollingIfNeeded()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        let pollTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        // Menu panels and drag sessions can move the main run loop out of its default mode. Common
        // modes keep the permission cache from freezing during exactly the flows that change
        // permissions.
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Asks macOS to register or prompt for the current process before showing manual guidance.
    ///
    /// The drag helper is useful once the user is in System Settings, but TCC permissions are
    /// ultimately granted to the current app's code identity. Calling the native request API first
    /// makes macOS resolve that identity itself instead of relying only on a file dragged into the
    /// Settings table.
    @discardableResult
    func requestSystemAccess(for permission: CotabbyPermissionKind) -> Bool {
        let granted: Bool

        switch permission {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            granted = AXIsProcessTrustedWithOptions(options)

        case .inputMonitoring:
            granted = CGRequestListenEventAccess()

        case .screenRecording:
            granted = CGRequestScreenCaptureAccess()
        }

        refresh()
        return granted
    }

    /// Returns the latest cached grant state for a specific permission kind.
    ///
    /// Keeping this switch here means higher-level UI can reason in terms of `CotabbyPermissionKind`
    /// instead of hard-coding three separate boolean properties everywhere.
    func isGranted(_ permission: CotabbyPermissionKind) -> Bool {
        switch permission {
        case .accessibility:
            accessibilityGranted
        case .inputMonitoring:
            inputMonitoringGranted
        case .screenRecording:
            screenRecordingGranted
        }
    }

    /// Core autocomplete depends on Accessibility and Input Monitoring. Screen Recording is
    /// optional (without it the app runs the text-only Fast Mode path), so it is intentionally
    /// excluded here via `CotabbyPermissionKind.isRequiredForAutocomplete`.
    var requiredPermissionsGranted: Bool {
        CotabbyPermissionKind.allCases
            .filter(\.isRequiredForAutocomplete)
            .allSatisfy(isGranted(_:))
    }

    /// Whether every permission Ghostype can use (required ones plus the optional Screen Recording
    /// enhancement) is granted. Surfaces that list all permissions (the menu-bar Permissions card)
    /// use this so they keep showing the still-missing optional permission instead of vanishing as
    /// soon as the required ones are satisfied. Does not gate autocomplete; that stays on
    /// `requiredPermissionsGranted`.
    var allPermissionsGranted: Bool {
        CotabbyPermissionKind.allCases.allSatisfy(isGranted(_:))
    }

    /// Shared opener used by onboarding and the menu-bar shortcuts.
    func openSettings(for permission: CotabbyPermissionKind) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

}

extension PermissionManager: SuggestionPermissionProviding {
    /// The coordinator subscribes through erased publishers so it can depend on a protocol instead
    /// of the concrete `@Published` storage details of `PermissionManager`.
    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        $inputMonitoringGranted.eraseToAnyPublisher()
    }

    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        $screenRecordingGranted.eraseToAnyPublisher()
    }
}
