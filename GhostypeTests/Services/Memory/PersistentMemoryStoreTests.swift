import CryptoKit
import XCTest
@testable import Ghostype

/// Tests for the encrypted suggestion-memory store. The contract: events persist across store
/// instances (the restart case from issue #446), rejects down-rank accepted phrases, nothing is
/// readable without the key, and `destroy()` removes both the file and the ability to decrypt.
///
/// The store is exercised against a temporary database file with an in-memory key store, so these
/// tests never touch the developer's login Keychain or real Application Support directory. All
/// database work happens on the store's serial queue; the tests only observe through its
/// synchronous public API.
@MainActor
final class PersistentMemoryStoreTests: XCTestCase {
    /// App-target MainActor classes crash the app-hosted runner when deallocated; keep them alive.
    private static var retained: [AnyObject] = []

    /// Key store that keeps the key in memory, so tests never write Keychain items. One shared key
    /// per test run mimics the Keychain: every store instance for the same "device" opens the
    /// same database, which is what the restart test relies on.
    private nonisolated struct EphemeralKeyStore: MemoryKeyStore {
        private static let sharedKey = SymmetricKey(size: .bits256)
        func existingKey() throws -> SymmetricKey? { Self.sharedKey }
        func createKey() throws -> SymmetricKey { Self.sharedKey }
        func deleteKey() throws {}
    }

    private var tempFile: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: PersistentMemoryStore!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-memory-test-\(UUID().uuidString).sqlite")
        suiteName = "cotabby.test.suggestionMemory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = PersistentMemoryStore(
            fileURL: tempFile,
            crypto: MemoryCrypto(keyStore: EphemeralKeyStore())
        )
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempFile)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeRecorder() -> MemoryRecorder {
        let recorder = MemoryRecorder(store: store, userDefaults: defaults, loadsMemory: false)
        Self.retained.append(recorder)
        return recorder
    }

    // MARK: - Persistence

    func test_persistThenReload_keepsLearnedPhrases() {
        let events = [
            MemoryEvent(kind: .accepted, text: "kind regards", bundleIdentifier: "com.apple.mail", date: Date()),
            MemoryEvent(kind: .accepted, text: "kind regards", bundleIdentifier: "com.apple.mail", date: Date()),
        ]
        store.persistAndWait(events)

        // A fresh store instance over the same file is the restart case: learning survives.
        let reopened = PersistentMemoryStore(
            fileURL: tempFile,
            crypto: MemoryCrypto(keyStore: EphemeralKeyStore())
        )
        let phrases = reopened.topPhrases(limit: 50).map(\.phrase)
        XCTAssertTrue(phrases.contains("kind regards"))
        XCTAssertTrue(phrases.contains("kind"))
        XCTAssertTrue(phrases.contains("regards"))
    }

    func test_nothingIsWrittenBeforeTheFirstEvent() {
        // Reads must not create the database file or (transitively) the Keychain key.
        XCTAssertEqual(store.counts().events, 0)
        XCTAssertTrue(store.topPhrases(limit: 10).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func test_rejectionDownRanksPhrase() {
        let accepted = MemoryEvent(
            kind: .accepted, text: "best practices", bundleIdentifier: "com.apple.mail", date: Date()
        )
        let rejected = MemoryEvent(
            kind: .rejected, text: "best practices", bundleIdentifier: "com.apple.mail", date: Date()
        )
        store.persistAndWait([accepted, accepted, rejected])

        let ranked = store.topPhrases(limit: 50)
        let phrase = ranked.first { $0.phrase == "best practices" }
        XCTAssertEqual(phrase?.acceptCount, 2)
        XCTAssertEqual(phrase?.rejectCount, 1)
        // Net evidence is 1: still positive, but weaker than a twice-accepted phrase would be.
        // Tolerance covers microseconds of recency decay between event creation and scoring.
        XCTAssertEqual(phrase?.score ?? 0, 1.0, accuracy: 1e-6)
    }

    func test_fullyRejectedPhraseNeverReachesVocabulary() {
        let rejected = MemoryEvent(
            kind: .rejected, text: "unwanted wording", bundleIdentifier: "com.apple.mail", date: Date()
        )
        store.persistAndWait([rejected])
        // The event is recorded (audit trail), but the phrase scores 0 and is excluded.
        XCTAssertEqual(store.counts().events, 1)
        XCTAssertTrue(store.topPhrases(limit: 50).allSatisfy { $0.phrase != "unwanted wording" })
    }

    func test_countsReflectEventsAndPhrases() {
        store.persistAndWait([
            MemoryEvent(kind: .accepted, text: "see you soon", bundleIdentifier: "com.apple.mail", date: Date()),
        ])
        let counts = store.counts()
        XCTAssertEqual(counts.events, 1)
        XCTAssertGreaterThan(counts.phrases, 0)
    }

    // MARK: - Encryption

    func test_sealedDataIsUnreadableWithoutTheKey() throws {
        // A different key store stands in for an attacker (or another Mac): without the Keychain
        // key, sealed blobs are opaque and decryption reports corruption instead of guessing.
        nonisolated struct OtherKeyStore: MemoryKeyStore {
            func existingKey() throws -> SymmetricKey? { SymmetricKey(size: .bits256) }
            func createKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
            func deleteKey() throws {}
        }
        let sealed = try MemoryCrypto(keyStore: EphemeralKeyStore()).seal("kind regards")
        XCTAssertThrowsError(try MemoryCrypto(keyStore: OtherKeyStore()).openString(sealed))
        // …while the right key round-trips.
        XCTAssertEqual(try MemoryCrypto(keyStore: EphemeralKeyStore()).openString(sealed), "kind regards")
    }

    // MARK: - Deletion
    func test_destroy_removesFileAndEmptiesVocabulary() throws {
        store.persistAndWait([
            MemoryEvent(kind: .accepted, text: "kind regards", bundleIdentifier: "com.apple.mail", date: Date()),
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        try store.destroy()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
        XCTAssertTrue(store.topPhrases(limit: 50).isEmpty)
        XCTAssertEqual(store.counts().events, 0)
    }

    // MARK: - Recorder privacy gate

    func test_recorder_refusesSecureFieldText() {
        // The recorder is the last boundary before text reaches the disk: secure-field text must
        // never be persisted, even if a call site forgets to check.
        let recorder = makeRecorder()
        recorder.recordAccepted("hunter2", bundleIdentifier: "com.apple.mail", isSecure: true)
        recorder.recordRejected("hunter2", bundleIdentifier: "com.apple.mail", isSecure: true)
        recorder.flush()
        XCTAssertEqual(store.counts().events, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func test_recorder_dropsEmptyText() {
        let recorder = makeRecorder()
        recorder.recordAccepted("   ", bundleIdentifier: "com.apple.mail", isSecure: false)
        recorder.flush()
        XCTAssertEqual(store.counts().events, 0)
    }
}
