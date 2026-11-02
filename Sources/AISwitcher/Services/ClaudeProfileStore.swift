import Foundation

/// Stable identity of one Claude login.
///
/// Claude's OAuth credential contains no account identifier and rotates both of
/// its tokens on every refresh, so token material can never distinguish two
/// logins. Claude Code records the account it is signed into in `~/.claude.json`,
/// which is the only identity available without a network request.
struct ClaudeAccountIdentity: Codable, Sendable, Equatable {
    var accountUUID: String
    var email: String?
    var displayName: String?
    var organizationUUID: String?

    enum CodingKeys: String, CodingKey {
        case accountUUID = "accountUuid"
        case email = "emailAddress"
        case displayName
        case organizationUUID = "organizationUuid"
    }

    /// Managed account identifier that survives token rotation.
    var accountID: String { "claude-" + accountUUID }

    /// Reference-compatible display label that never shows a full email address.
    var label: String {
        email?.components(separatedBy: "@").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? displayName?.components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Claude"
    }
}

/// Reads the account identity Claude Code stores beside its credential.
///
/// The file belongs to the CLI; the switcher only reads it and never writes it.
/// It describes whichever login Claude Code last recorded, so it is authoritative
/// exactly when the CLI — not the switcher — produced the live credential.
final class ClaudeProfileStore: @unchecked Sendable {
    static let shared = ClaudeProfileStore()

    private struct Settings: Decodable {
        let oauthAccount: ClaudeAccountIdentity?
    }

    /// Cheap change detector so the CLI's large settings file is parsed rarely.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var cached: (stamp: Stamp, identity: ClaudeAccountIdentity?)?

    /// Override the path to isolate tests from the user's real Claude Code settings.
    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) {
        self.fileURL = fileURL
    }

    /// Identity of the login Claude Code last recorded.
    ///
    /// - Returns: The recorded account, or `nil` when the file is missing,
    ///   unreadable, or holds no OAuth account.
    /// - Side effects: Re-parses the settings file only after its size or
    ///   modification date changes. No credential material is read or logged.
    func liveIdentity() -> ClaudeAccountIdentity? {
        lock.lock()
        defer { lock.unlock() }
        let stamp = currentStamp()
        if let cached, cached.stamp == stamp { return cached.identity }
        let identity = decodeIdentity()
        cached = (stamp, identity)
        return identity
    }

    private func currentStamp() -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return Stamp(
            modified: attributes?[.modificationDate] as? Date,
            size: attributes?[.size] as? Int ?? -1
        )
    }

    private func decodeIdentity() -> ClaudeAccountIdentity? {
        guard let data = try? Data(contentsOf: fileURL),
            let settings = try? JSONDecoder().decode(Settings.self, from: data),
            let identity = settings.oauthAccount, !identity.accountUUID.isEmpty
        else { return nil }
        return identity
    }
}
