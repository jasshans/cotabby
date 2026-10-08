import CryptoKit
import Foundation
import Security

/// File overview:
/// Column-level encryption for the suggestion-memory SQLite database.
///
/// Why column-level instead of sealing the whole file (the `TypingHistoryVault` approach): the
/// database is queried and updated incrementally — phrase statistics need indexed lookup and the
/// event log needs pruning — so the whole file cannot be re-sealed on every write. Instead, every
/// sensitive TEXT value is sealed with AES-GCM before it reaches SQLite, and the database file
/// itself only ever holds ciphertext blobs plus non-sensitive counters and timestamps. A copied
/// database file, a backup, or another app reading Application Support learns nothing about what
/// was typed.
///
/// The 256-bit key lives in the login Keychain as a generic-password item, `ThisDeviceOnly`, so it
/// never syncs and the database cannot be opened on another Mac. Like the typing-history vault, no
/// key is created until the first persist, so installing the app never touches the Keychain.
///
/// This is a value type with no shared mutable state, so the store can encrypt and decrypt on its
/// serial queue without touching the main actor. Errors are surfaced rather than swallowed: a
/// failed decrypt must not be mistaken for "no data".
nonisolated struct MemoryCrypto: Sendable {
    enum CryptoError: Error, Equatable {
        case keychain(OSStatus)
        case corruptData
    }

    private let keyStore: any MemoryKeyStore

    init(keyStore: any MemoryKeyStore) {
        self.keyStore = keyStore
    }

    /// The production crypto: keyed per bundle identifier so the release app and the dev build
    /// never share (or clobber) each other's key.
    static func standard(bundle: Bundle = .main) -> MemoryCrypto {
        let identifier = bundle.bundleIdentifier ?? "com.jasshans.ghostype"
        return MemoryCrypto(keyStore: KeychainMemoryKeyStore(service: "\(identifier).suggestion-memory"))
    }

    /// Seals plaintext into a single combined blob (nonce + ciphertext + tag) for one BLOB column.
    /// Creates the Keychain key on first use.
    func seal(_ plaintext: Data) throws -> Data {
        let key = try keyStore.existingKey() ?? keyStore.createKey()
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CryptoError.corruptData
        }
        return combined
    }

    func seal(_ string: String) throws -> Data {
        try seal(Data(string.utf8))
    }

    func open(_ sealed: Data) throws -> Data {
        guard let key = try keyStore.existingKey() else {
            // Sealed data without its key can never be opened again; report it instead of
            // returning empty so the caller does not overwrite it as if it were empty.
            throw CryptoError.corruptData
        }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key)
        else {
            throw CryptoError.corruptData
        }
        return plaintext
    }

    func openString(_ sealed: Data) throws -> String {
        let data = try open(sealed)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CryptoError.corruptData
        }
        return string
    }

    /// Deletes the Keychain key. After this, even an undeleted copy of the database file (Time
    /// Machine, a sync folder) can no longer be decrypted.
    func rotateKey() throws {
        try keyStore.deleteKey()
    }
}

/// Where the memory key lives. A protocol so tests can keep keys in memory instead of writing
/// items into the developer's login Keychain.
nonisolated protocol MemoryKeyStore: Sendable {
    func existingKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
    func deleteKey() throws
}

/// The production key store: one generic-password item in the login Keychain.
nonisolated struct KeychainMemoryKeyStore: MemoryKeyStore {
    let service: String
    private static let account = "memory-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }

    func existingKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        // `item` is a CFData when the query asks for data; bridging to Data copies the bytes.
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw MemoryCrypto.CryptoError.keychain(status)
        }
        return SymmetricKey(data: data)
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var attributes = baseQuery
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Ghostype suggestion memory key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw MemoryCrypto.CryptoError.keychain(status) }
        return key
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MemoryCrypto.CryptoError.keychain(status)
        }
    }
}
