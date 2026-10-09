import CryptoKit
import Foundation
import Logging
import SQLite3

/// File overview:
/// Encrypted SQLite storage for suggestion memory: the accept/reject event log and the phrase
/// statistics derived from it. This is what makes learning survive restarts (upstream issue #446):
/// the recorder captures events, this store persists them, and the context provider reads the
/// ranked phrases back on the next launch.
///
/// Why SQLite and not the sealed-archive pattern `TypingHistoryVault` uses: memory is queried,
/// not just loaded wholesale. Phrase statistics need indexed lookup and ranking (`topPhrases`),
/// and the event log needs bounded pruning — both are natural SQL, while a sealed archive would
/// have to decrypt and rewrite the whole file on every keystroke batch. Sensitive text is still
/// encrypted: every TEXT value is sealed with AES-GCM (see `MemoryCrypto`) before it reaches a
/// column, so the database file only ever holds ciphertext blobs plus non-sensitive counters.
///
/// Concurrency: `nonisolated final class` with every database touch confined to a private serial
/// queue — the same "explicit serialization" approach as `LlamaRuntimeCore`, which also guards a
/// native pointer this way. The `OpaquePointer` handle never leaves the queue. `persist` returns
/// immediately (fire-and-forget); the other public methods barrier on the queue, so they never run
/// concurrently with a write but do block the caller until the queue drains.
///
/// Nothing is written until the first event is recorded: reads never create the file or the
/// Keychain key, so installing the app leaves no trace of this feature on disk.
nonisolated final class PersistentMemoryStore: @unchecked Sendable {
    enum StoreError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case closeFailed(String)
    }

    /// Bump when the schema changes and add the `ALTER TABLE` steps to `runMigrations()`.
    static let schemaVersion = 4
    /// The event log is an audit trail; phrase_stats carries the durable learning.
    static let maximumEvents = 20_000
    static let maximumPhrases = 5_000

    private let fileURL: URL
    private let crypto: MemoryCrypto
    private let queue = DispatchQueue(label: "com.jasshans.ghostype.persistent-memory", qos: .utility)
    /// Owned by the serial queue: created, used, and closed only inside `queue` blocks.
    private var db: OpaquePointer?

    init(
        fileURL: URL = PersistentMemoryStore.standardFileURL(),
        crypto: MemoryCrypto = MemoryCrypto.standard()
    ) {
        self.fileURL = fileURL
        self.crypto = crypto
    }

    /// `Application Support/<app name>/SuggestionMemory.sqlite`, next to the typing-history
    /// archive. Keyed off the bundle name (not identifier) so the file path matches the vault's
    /// convention; the encryption key (not the path) is what separates release from dev builds.
    static func standardFileURL(bundle: Bundle = .main) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Ghostype"
        return support.appendingPathComponent(appName).appendingPathComponent("SuggestionMemory.sqlite")
    }

    deinit {
        // The queue never retains self (blocks capture it weakly), so deinit cannot run on the
        // queue itself; closing here is safe.
        if let db { _ = sqlite3_close(db) }
    }

    // MARK: - Public API (all hop to the serial queue)

    /// Enqueues one debounced batch. Returns immediately; the write lands in a single transaction.
    func persist(_ events: [MemoryEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [weak self] in
            do {
                try self?.persistOnQueue(events)
            } catch {
                CotabbyLogger.app.error("Suggestion memory persist failed: \(error)")
            }
        }
    }

    /// Enqueues a batch and waits for it. Used by the termination flush, when the process may
    /// exit before an async block would run.
    func persistAndWait(_ events: [MemoryEvent]) {
        guard !events.isEmpty else { return }
        queue.sync {
            do {
                try self.persistOnQueue(events)
            } catch {
                CotabbyLogger.app.error("Suggestion memory persist failed: \(error)")
            }
        }
    }

    /// Barrier: returns after every previously enqueued write has finished.
    func drain() {
        queue.sync {}
    }

    /// Highest-scoring phrases for prompt conditioning, decrypted and ranked. Never creates the
    /// database file: no file means no memory yet, which reads as empty.
    func topPhrases(limit: Int) -> [LearnedPhrase] {
        topPhrases(limit: limit, bundleId: nil)
    }

    /// Per-app vocabulary with global fallback: the app's own top phrases first, then the
    /// global aggregate fills whatever the app hasn't earned yet. A new app starts on the
    /// global vocabulary and grows its own as its events land. App phrases always lead —
    /// wording learned in this app outranks globally popular wording for this field.
    func topPhrases(limit: Int, bundleId: String?) -> [LearnedPhrase] {
        queue.sync {
            do {
                guard try openIfNeeded(create: false) else { return [] }
                var seen = Set<String>()
                var result: [LearnedPhrase] = []
                if let bundleId, !bundleId.isEmpty {
                    result = try rankedPhrases(bundleId: bundleId, limit: limit, seen: &seen)
                }
                if result.count < limit {
                    let global = try rankedPhrases(
                        bundleId: "", limit: limit - result.count, seen: &seen
                    )
                    result.append(contentsOf: global)
                }
                return result
            } catch {
                CotabbyLogger.app.error("Suggestion memory ranking failed: \(error)")
                return []
            }
        }
    }

    /// All positively-scored phrases for one bundle bucket ('': global), decrypted and scored.
    /// `seen` carries phrase hashes already taken by a higher-priority bucket so the global
    /// fill never duplicates the app's own phrases.
    private func rankedPhrases(
        bundleId: String, limit: Int, seen: inout Set<String>
    ) throws -> [LearnedPhrase] {
        let stmt = try prepare(
            """
            SELECT phrase_hash, phrase_enc, accept_count, typed_count, reject_count,
                   soft_reject_count, last_used
            FROM phrase_stats WHERE bundle_id = ?;
            """
        )
        defer { _ = sqlite3_finalize(stmt) }
        try bindText(stmt, 1, bundleId)
        let now = Date()
        var ranked: [(phrase: LearnedPhrase, score: Double)] = []
        while try step(stmt) {
            guard let hash = columnText(stmt, 0), seen.insert(hash).inserted else { continue }
            guard let encrypted = columnBlob(stmt, 1) else { continue }
            let phrase: String
            do {
                phrase = try crypto.openString(encrypted)
            } catch {
                // One undecryptable row (e.g. the key was rotated elsewhere) must not
                // poison the rest of the vocabulary.
                continue
            }
            let accepts = Int(sqlite3_column_int64(stmt, 2))
            let typed = Int(sqlite3_column_int64(stmt, 3))
            let rejects = Int(sqlite3_column_int64(stmt, 4))
            let softRejects = Int(sqlite3_column_int64(stmt, 5))
            let lastUsed = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let score = MemoryPhraseExtractor.score(
                acceptCount: accepts, typedCount: typed, rejectCount: rejects,
                softRejectCount: softRejects, lastUsed: lastUsed, now: now
            )
            guard score > 0 else { continue }
            ranked.append((
                phrase: LearnedPhrase(
                    phrase: phrase, acceptCount: accepts, typedCount: typed,
                    rejectCount: rejects, softRejectCount: softRejects,
                    lastUsed: lastUsed, score: score
                ),
                score: score
            ))
        }
        return ranked.sorted { $0.score > $1.score }.prefix(limit).map(\.phrase)
    }

    /// (events, phrases) for the Settings UI. Never creates the database file.
    func counts() -> (events: Int, phrases: Int) {
        queue.sync {
            do {
                guard try openIfNeeded(create: false) else { return (0, 0) }
                return (
                    try scalarInt("SELECT COUNT(*) FROM memory_events;"),
                    try scalarInt("SELECT COUNT(*) FROM phrase_stats;")
                )
            } catch {
                CotabbyLogger.app.error("Suggestion memory counts failed: \(error)")
                return (0, 0)
            }
        }
    }

    /// Deletes the database file and rotates the encryption key, so even a surviving copy of the
    /// file (Time Machine, a sync folder) can never be decrypted again. Afterwards the store is as
    /// if never used: the next persist recreates both.
    func destroy() throws {
        try queue.sync {
            if let db {
                guard sqlite3_close(db) == SQLITE_OK else {
                    throw StoreError.closeFailed(String(cString: sqlite3_errmsg(db)))
                }
                self.db = nil
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try crypto.rotateKey()
        }
    }

    // MARK: - Queue-confined implementation

    /// Opens the database, creating the file and schema on first persist. Returns false (without
    /// creating anything) when there is no file yet and `create` is false.
    private func openIfNeeded(create: Bool) throws -> Bool {
        if db != nil { return true }
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if !exists, !create { return false }
        if !exists {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (exists ? 0 : SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let path = fileURL.path
        let rc = path.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.openFailed("Could not open suggestion memory database (rc=\(rc)).")
        }
        db = handle
        do {
            try applySchema()
            if !exists {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
                )
            }
        } catch {
            _ = sqlite3_close(handle)
            db = nil
            throw error
        }
        return true
    }

    private func applySchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS memory_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text_enc BLOB NOT NULL,
                app_bundle_id TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_memory_events_created ON memory_events(created_at);
            CREATE TABLE IF NOT EXISTS phrase_stats(
                phrase_hash TEXT NOT NULL,
                -- Owning app for per-app vocabulary. '' is the global aggregate across apps:
                -- every event writes both its app row and the global row, so the global
                -- vocabulary keeps working while per-app rankings grow underneath it.
                bundle_id TEXT NOT NULL DEFAULT '',
                phrase_enc BLOB NOT NULL,
                accept_count INTEGER NOT NULL DEFAULT 0,
                typed_count INTEGER NOT NULL DEFAULT 0,
                reject_count INTEGER NOT NULL DEFAULT 0,
                soft_reject_count INTEGER NOT NULL DEFAULT 0,
                last_used REAL NOT NULL,
                PRIMARY KEY(phrase_hash, bundle_id)
            );
            CREATE INDEX IF NOT EXISTS idx_phrase_stats_last_used ON phrase_stats(last_used);
            CREATE INDEX IF NOT EXISTS idx_phrase_stats_bundle ON phrase_stats(bundle_id);
            CREATE TABLE IF NOT EXISTS kv_store(
                key TEXT PRIMARY KEY,
                value_enc BLOB NOT NULL
            );
            """)
        try runMigrations()
    }

    /// Versioned schema with a migration stub: v0 (fresh) and v1 share the schema above. Future
    /// versions add their `ALTER TABLE` steps here before bumping `schemaVersion`.
    private func runMigrations() throws {
        let version = try userVersion()
        if version > Self.schemaVersion {
            throw StoreError.openFailed(
                "Suggestion memory database is from a newer Ghostype version (\(version))."
            )
        }
        // v0 -> v1: initial schema, already applied by applySchema().
        // v1 -> v2: phrase hashes are now HMAC-SHA256 under a per-database salt (the old
        // unsalted SHA-256 was dictionary-confirmable). phrase_stats is derived data, so
        // drop it; it rebuilds from new accept/dismiss events.
        if version < 2 {
            try exec("DELETE FROM phrase_stats;")
        }
        // v2 -> v3: index on last_used so the prune's ORDER BY ... LIMIT is served from
        // the index instead of sorting the whole table on every persist batch.
        if version < 3 {
            try exec("CREATE INDEX IF NOT EXISTS idx_phrase_stats_last_used ON phrase_stats(last_used);")
        }
        // v3 -> v4: phrase_stats becomes per-(phrase, app). The primary key changes, so the
        // table is rebuilt: existing rows keep their counts and become the global ('') aggregate.
        // Two new counters arrive: typed_count (phrases the user produced by typing) and
        // soft_reject_count (visible suggestions typed over). Both default 0, so old rows score
        // exactly as before until new evidence lands.
        if version < 4 {
            try exec("""
                CREATE TABLE phrase_stats_new(
                    phrase_hash TEXT NOT NULL,
                    bundle_id TEXT NOT NULL DEFAULT '',
                    phrase_enc BLOB NOT NULL,
                    accept_count INTEGER NOT NULL DEFAULT 0,
                    typed_count INTEGER NOT NULL DEFAULT 0,
                    reject_count INTEGER NOT NULL DEFAULT 0,
                    soft_reject_count INTEGER NOT NULL DEFAULT 0,
                    last_used REAL NOT NULL,
                    PRIMARY KEY(phrase_hash, bundle_id)
                );
                INSERT INTO phrase_stats_new(
                    phrase_hash, bundle_id, phrase_enc, accept_count, typed_count,
                    reject_count, soft_reject_count, last_used
                ) SELECT phrase_hash, '', phrase_enc, accept_count, 0, reject_count, 0, last_used
                  FROM phrase_stats;
                DROP TABLE phrase_stats;
                ALTER TABLE phrase_stats_new RENAME TO phrase_stats;
                CREATE INDEX idx_phrase_stats_last_used ON phrase_stats(last_used);
                CREATE INDEX idx_phrase_stats_bundle ON phrase_stats(bundle_id);
                """)
        }
        try setUserVersion(Self.schemaVersion)
    }

    private func persistOnQueue(_ events: [MemoryEvent]) throws {
        _ = try openIfNeeded(create: true)
        // The salt is constant for the database's lifetime; fetch it once per batch instead
        // of once per phrase (each fetch is a statement cycle plus an AES-GCM open).
        let salt = try phraseHashSalt()
        try inTransaction {
            for event in events {
                try insertEvent(event)
                // Phrase learning is the durable part; the event log is the audit trail.
                for phrase in MemoryPhraseExtractor.phrases(from: event.text) {
                    try upsertPhrase(
                        phrase, kind: event.kind, bundleId: event.bundleIdentifier,
                        date: event.date, salt: salt
                    )
                }
            }
            try prune()
        }
    }

    private func insertEvent(_ event: MemoryEvent) throws {
        let stmt = try prepare(
            "INSERT INTO memory_events(kind, text_enc, app_bundle_id, created_at) VALUES (?, ?, ?, ?);"
        )
        defer { _ = sqlite3_finalize(stmt) }
        try bindText(stmt, 1, event.kind.rawValue)
        try bindBlob(stmt, 2, try crypto.seal(event.text))
        try bindText(stmt, 3, event.bundleIdentifier)
        try bindDouble(stmt, 4, event.date.timeIntervalSince1970)
        let hasRow = try step(stmt)
        guard !hasRow else { throw StoreError.stepFailed("INSERT returned a row.") }
    }

    /// Per-database salt for phrase hashes (see `MemoryPhraseExtractor.phraseHash`). Generated
    /// once, sealed with the database key, and kept in `kv_store`. A salt unique to this
    /// database means a precomputed dictionary of common phrases can't confirm what the
    /// user types, even with the database file in hand.
    private func phraseHashSalt() throws -> Data {
        _ = try openIfNeeded(create: true)
        if let sealed = try kvGet("phrase_hash_salt") {
            return try crypto.open(sealed)
        }
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try kvSet("phrase_hash_salt", value: try crypto.seal(salt))
        return salt
    }

    private func kvGet(_ key: String) throws -> Data? {
        let stmt = try prepare("SELECT value_enc FROM kv_store WHERE key = ?;")
        defer { _ = sqlite3_finalize(stmt) }
        try bindText(stmt, 1, key)
        guard try step(stmt) else { return nil }
        return columnBlob(stmt, 0)
    }

    private func kvSet(_ key: String, value: Data) throws {
        let stmt = try prepare(
            "INSERT INTO kv_store(key, value_enc) VALUES (?, ?) " +
            "ON CONFLICT(key) DO UPDATE SET value_enc = excluded.value_enc;"
        )
        defer { _ = sqlite3_finalize(stmt) }
        try bindText(stmt, 1, key)
        try bindBlob(stmt, 2, value)
        _ = try step(stmt)
    }

    private func upsertPhrase(
        _ phrase: String, kind: MemoryEventKind, bundleId: String, date: Date, salt: Data
    ) throws {
        // Each kind feeds its own counter; the score weights them (see MemoryPhraseExtractor).
        // Typed text is the cold-start fix: it is the user's own production, not a suggestion
        // they accepted, so it earns its own counter rather than inflating accept_count.
        let (accepts, typed, rejects, softRejects): (Int64, Int64, Int64, Int64)
        switch kind {
        case .accepted: (accepts, typed, rejects, softRejects) = (1, 0, 0, 0)
        case .typed: (accepts, typed, rejects, softRejects) = (0, 1, 0, 0)
        case .rejected: (accepts, typed, rejects, softRejects) = (0, 0, 1, 0)
        case .softRejected: (accepts, typed, rejects, softRejects) = (0, 0, 0, 1)
        }
        let hash = MemoryPhraseExtractor.phraseHash(phrase, salt: salt)
        let sealed = try crypto.seal(phrase)
        let timestamp = date.timeIntervalSince1970
        let stmt = try prepare(
            """
            INSERT INTO phrase_stats(
                phrase_hash, bundle_id, phrase_enc, accept_count, typed_count,
                reject_count, soft_reject_count, last_used
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(phrase_hash, bundle_id) DO UPDATE SET
                phrase_enc = excluded.phrase_enc,
                accept_count = phrase_stats.accept_count + excluded.accept_count,
                typed_count = phrase_stats.typed_count + excluded.typed_count,
                reject_count = phrase_stats.reject_count + excluded.reject_count,
                soft_reject_count = phrase_stats.soft_reject_count + excluded.soft_reject_count,
                last_used = excluded.last_used;
            """
        )
        defer { _ = sqlite3_finalize(stmt) }
        // Every event lands twice: once in the global aggregate (bundle_id = '') and once in
        // the event's app. The global row keeps the old behavior working; the app row grows
        // the per-app vocabulary underneath it. When the bundle is empty there is only one row.
        var bundleIds = [""]
        if !bundleId.isEmpty { bundleIds.append(bundleId) }
        for target in bundleIds {
            try bindText(stmt, 1, hash)
            try bindText(stmt, 2, target)
            try bindBlob(stmt, 3, sealed)
            try bindInt64(stmt, 4, accepts)
            try bindInt64(stmt, 5, typed)
            try bindInt64(stmt, 6, rejects)
            try bindInt64(stmt, 7, softRejects)
            try bindDouble(stmt, 8, timestamp)
            _ = try step(stmt)
            try reset(stmt)
        }
    }

    private func prune() throws {
        try exec(
            "DELETE FROM memory_events WHERE id NOT IN " +
            "(SELECT id FROM memory_events ORDER BY id DESC LIMIT \(Self.maximumEvents));"
        )
        // The ORDER BY last_used is served by idx_phrase_stats_last_used, but skip the
        // delete entirely unless the table actually exceeds the cap — the common case
        // is far below it, and even an index walk is wasted work then.
        if try phraseCount() > Self.maximumPhrases {
            try exec(
                "DELETE FROM phrase_stats WHERE phrase_hash NOT IN " +
                "(SELECT phrase_hash FROM phrase_stats ORDER BY last_used DESC LIMIT \(Self.maximumPhrases));"
            )
        }
    }

    private func phraseCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM phrase_stats;")
        defer { _ = sqlite3_finalize(stmt) }
        guard try step(stmt) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - sqlite3 helpers (all assume the caller's statement lifecycle)

    private func errorMessage() -> String {
        guard let db else { return "database not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.openFailed("database not open") }
        let rc = sql.withCString { sqlite3_exec(db, $0, nil, nil, nil) }
        guard rc == SQLITE_OK else { throw StoreError.stepFailed(errorMessage()) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StoreError.openFailed("database not open") }
        var stmt: OpaquePointer?
        let rc = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
        guard rc == SQLITE_OK, let stmt else { throw StoreError.prepareFailed(errorMessage()) }
        return stmt
    }

    /// Returns true while rows remain (`SQLITE_ROW`), false on `SQLITE_DONE`.
    private func step(_ stmt: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw StoreError.stepFailed(errorMessage())
    }

    private func inTransaction(_ work: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try work()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version;")
        defer { _ = sqlite3_finalize(stmt) }
        guard try step(stmt) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version=\(version);")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { _ = sqlite3_finalize(stmt) }
        guard try step(stmt) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// `SQLITE_TRANSIENT` is a C macro and is not imported into Swift; this is the standard
    /// spelling. It tells SQLite to copy the bytes, so the Swift buffer only needs to live for
    /// the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) throws {
        let rc = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, Self.transient) }
        guard rc == SQLITE_OK else { throw StoreError.stepFailed(errorMessage()) }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data) throws {
        guard !value.isEmpty else { throw StoreError.stepFailed("Refusing to bind an empty blob.") }
        let rc = value.withUnsafeBytes {
            sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), Self.transient)
        }
        guard rc == SQLITE_OK else { throw StoreError.stepFailed(errorMessage()) }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(stmt, index, value) == SQLITE_OK else {
            throw StoreError.stepFailed(errorMessage())
        }
    }

    private func bindInt64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else {
            throw StoreError.stepFailed(errorMessage())
        }
    }

    private func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    /// Resets a prepared statement so it can be re-bound and re-stepped. Used when one
    /// statement serves several rows (the global + per-app upsert pair).
    private func reset(_ stmt: OpaquePointer) throws {
        guard sqlite3_reset(stmt) == SQLITE_OK else { throw StoreError.stepFailed(errorMessage()) }
    }
}
