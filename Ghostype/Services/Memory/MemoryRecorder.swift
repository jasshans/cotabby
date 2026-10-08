import Combine
import Foundation
import Logging

/// File overview:
/// The write path for suggestion memory: captures accept/reject events from the suggestion
/// coordinator and persists them to `PersistentMemoryStore` in debounced batches.
///
/// Why the coordinator talks to this instead of the store directly: the coordinator is already a
/// large state machine, and persistence has its own concerns — an enable toggle, a secure-field
/// gate, batching, a pending buffer, and lifecycle flushes — that would otherwise be smeared
/// across the accept/reject call sites. This class is the single seam: the coordinator makes two
/// narrow calls (`recordAccepted` / `recordRejected`), and everything else lives here.
///
/// Threading: `@MainActor`, mirroring `TypingHistoryStore`. The coordinator already runs on the
/// main actor, the settings UI observes this object, and every store call hops to the store's own
/// serial queue, so no database work ever blocks the main thread.
///
/// Privacy: secure fields are refused here, even though the coordinator only records supported
/// (non-secure) suggestions. Two gates protect the invariant, so a future call site cannot
/// accidentally record a password by forgetting to check.
@MainActor
final class MemoryRecorder: ObservableObject, SuggestionMemoryRecording {
    enum Status: Equatable {
        case loading
        case ready
        case unavailable(String)
    }

    /// How long after the last recorded event the batch is written. Short enough that a crash
    /// loses at most ~2s of learning, long enough that a burst of Tab presses becomes one
    /// transaction.
    static let persistDelayNanoseconds: UInt64 = 2_000_000_000

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: Status = .loading
    @Published private(set) var eventCount = 0
    @Published private(set) var phraseCount = 0
    @Published private(set) var clearError: String?

    /// Fired after every persist and after a fresh enable, so `MemoryContextProvider` can reload
    /// its vocabulary cache. Assigned by the composition root, not by the coordinator.
    var onDidPersist: (() -> Void)?

    private let store: PersistentMemoryStore
    private let userDefaults: UserDefaults
    private var pending: [MemoryEvent] = []
    private var persistTask: Task<Void, Never>?

    private enum DefaultsKey {
        static let isEnabled = "cotabbySuggestionMemoryEnabled"
    }

    init(
        store: PersistentMemoryStore,
        userDefaults: UserDefaults = .standard,
        loadsMemory: Bool = true
    ) {
        self.store = store
        self.userDefaults = userDefaults
        // A stored value wins; a fresh install starts with learning on. In the test host nothing
        // is loaded, so tests (and the dev menu) never touch the developer's real database.
        if let stored = userDefaults.object(forKey: DefaultsKey.isEnabled) as? Bool {
            isEnabled = stored
        } else {
            isEnabled = MemoryPreferences.defaults.isEnabled
        }
        if loadsMemory {
            Task { [weak self] in
                await self?.loadCounts()
                self?.onDidPersist?()
            }
        } else {
            status = .ready
        }
    }

    // MARK: - Event capture (called by the suggestion coordinator)

    /// Records an accepted suggestion chunk. `isSecure` is re-checked here: the acceptance path is
    /// already gated on supported capabilities, but this is the last boundary before text hits the
    /// disk, so the check is repeated rather than trusted.
    func recordAccepted(_ text: String, bundleIdentifier: String, isSecure: Bool) {
        record(kind: .accepted, text: text, bundleIdentifier: bundleIdentifier, isSecure: isSecure)
    }

    /// Records a dismissed suggestion (Esc) so its wording can be down-ranked. Corrections are
    /// excluded by the caller: dismissing a typo fix is not evidence against the corrected word.
    func recordRejected(_ text: String, bundleIdentifier: String, isSecure: Bool) {
        record(kind: .rejected, text: text, bundleIdentifier: bundleIdentifier, isSecure: isSecure)
    }

    private func record(kind: MemoryEventKind, text: String, bundleIdentifier: String, isSecure: Bool) {
        guard isEnabled, !isSecure, isAvailable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending.append(MemoryEvent(
            kind: kind, text: trimmed, bundleIdentifier: bundleIdentifier, date: Date()
        ))
        // Bound the in-memory buffer: if persistence ever stalls, the buffer must not grow
        // without limit.
        if pending.count > 500 {
            persistNow(wait: false)
        } else {
            schedulePersist()
        }
    }

    private var isAvailable: Bool {
        if case .unavailable = status { return false }
        return true
    }

    // MARK: - Preferences

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: DefaultsKey.isEnabled)
        if enabled {
            // The provider's cache was emptied while the feature was off; reload it now.
            Task { [weak self] in
                await self?.loadCounts()
                self?.onDidPersist?()
            }
        } else {
            // Turning memory off stops learning immediately. Stored data is kept — "Clear memory…"
            // is the explicit delete — so re-enabling restores the profile.
            persistTask?.cancel()
            persistTask = nil
            pending = []
            onDidPersist?()
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.persistNow(wait: false)
        }
    }

    private func persistNow(wait: Bool) {
        let events = pending
        pending = []
        guard !events.isEmpty else { return }
        if wait {
            // Synchronous, so the process cannot exit mid-transaction.
            store.persistAndWait(events)
        } else {
            store.persist(events)
        }
        // Refresh the Settings counts and the vocabulary cache off the critical path.
        Task.detached(priority: .utility) { [weak self, store] in
            let counts = store.counts()
            await MainActor.run { [weak self] in
                self?.eventCount = counts.events
                self?.phraseCount = counts.phrases
                self?.onDidPersist?()
            }
        }
    }

    private func loadCounts() async {
        let counts = await Task.detached(priority: .utility) { [store] in
            store.counts()
        }.value
        eventCount = counts.events
        phraseCount = counts.phrases
        if status == .loading {
            status = .ready
        }
    }

    /// Writes any pending events immediately. Called from `applicationWillTerminate`, where there
    /// is no time left for the debounced save.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        persistNow(wait: true)
    }

    // MARK: - Deletion

    /// Deletes the database file and rotates the encryption key (see `PersistentMemoryStore`).
    /// The in-memory buffer is dropped first so a late flush cannot resurrect deleted data.
    func clearAll() {
        persistTask?.cancel()
        persistTask = nil
        pending = []
        do {
            try store.destroy()
            clearError = nil
        } catch {
            clearError = "Suggestion memory couldn't be deleted: \(error.localizedDescription)"
            CotabbyLogger.app.error("Suggestion memory could not be deleted: \(error)")
            return
        }
        eventCount = 0
        phraseCount = 0
        status = .ready
        onDidPersist?()
    }
}
