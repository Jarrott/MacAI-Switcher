import Foundation

/// Writes credential material atomically and restricts it to the current user.
/// The permission update is part of the operation and failures are reported to
/// the caller without deleting a pre-existing live credential.
enum SecureFileWriter {
    /// Atomically write sensitive bytes and apply owner-only POSIX permissions.
    ///
    /// - Parameters:
    ///   - data: Credential bytes to persist.
    ///   - url: Explicit destination file URL; its parent must already exist.
    /// - Throws: The underlying atomic write or permission-update error.
    /// - Side effects: Replaces the destination file and sets mode `0600`.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
