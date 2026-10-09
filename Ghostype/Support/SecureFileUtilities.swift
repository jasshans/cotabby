import Foundation

/// File overview:
/// Best-effort helpers that lock diagnostic files down to owner-only access, matching the
/// suggestion-memory database and typing-history vault precedent (both 0600). Debug sinks can
/// carry full prompts, screenshots, or AX text, so they get the same treatment even though
/// they only exist under explicit debug flags.
///
/// All helpers are best-effort (`try?` internally): a failed chmod must never break logging.
enum SecureFileUtilities {
    /// Creates an empty file at `url` when missing, then ensures it is owner-read/write-only.
    /// Also tightens permissions when the file already exists.
    @discardableResult
    static func createSecureEmptyFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else { return false }
        }
        setOwnerOnlyFilePermissions(url: url)
        return true
    }

    /// Writes `data` to `url` (overwriting) and ensures the result is owner-read/write-only.
    static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        setOwnerOnlyFilePermissions(url: url)
    }

    /// Writes `string` to `url` (overwriting) and ensures the result is owner-read/write-only.
    static func secureWrite(_ string: String, to url: URL, encoding: String.Encoding = .utf8) throws {
        try string.write(to: url, atomically: true, encoding: encoding)
        setOwnerOnlyFilePermissions(url: url)
    }

    /// Best-effort chmod 0600 on a file.
    static func setOwnerOnlyFilePermissions(url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Best-effort chmod 0700 on a directory, so its listing isn't visible to other users.
    static func setOwnerOnlyDirectoryPermissions(url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    /// Creates a directory (with intermediates) and locks it to owner-only access.
    static func createSecureDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setOwnerOnlyDirectoryPermissions(url: url)
    }

    /// Keeps only the newest `keep` files in `directory` (by creation date), best-effort.
    static func evictOldestFiles(in directory: URL, keepNewest keep: Int) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ), urls.count > keep else { return }
        let oldestFirst = urls.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d0 < d1
        }
        for url in oldestFirst.prefix(urls.count - keep) {
            try? fileManager.removeItem(at: url)
        }
    }
}
