import CryptoKit
import Foundation

/// Parsed contents of a Codex `~/.codex/auth.json` file.
struct CodexAuth: Codable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: Tokens?
    var lastRefresh: String?

    struct Tokens: Codable {
        var idToken: String?
        var accessToken: String?
        var refreshToken: String?
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountID = "account_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    // MARK: Derived identity from the id_token JWT

    private var idClaims: [String: Any]? {
        guard let t = tokens?.idToken else { return nil }
        return JWT.claims(t)
    }

    private var authClaims: [String: Any]? {
        idClaims?["https://api.openai.com/auth"] as? [String: Any]
    }

    var email: String? { idClaims?["email"] as? String }
    var name: String? { idClaims?["name"] as? String }
    var accountID: String? {
        (authClaims?["chatgpt_account_id"] as? String) ?? tokens?.accountID
    }
    var planType: String? { authClaims?["chatgpt_plan_type"] as? String }

    /// Access-token expiry, used to know when a refresh is needed.
    var accessTokenExpiry: Date? {
        guard let t = tokens?.accessToken,
            let c = JWT.claims(t),
            let exp = c["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Reads, snapshots and swaps the Codex CLI credential file.
///
/// Account switching in the real app is just replacing `~/.codex/auth.json`
/// with a previously saved snapshot — this class encapsulates that.
final class CodexCredentialStore: Sendable {
    static let shared = CodexCredentialStore()

    let authURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    /// Directory where per-account credential snapshots are kept.
    let snapshotsDir: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher/codex-accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        snapshotsDir = support
    }

    /// The credential file currently active on disk, if any.
    func currentAuth() -> CodexAuth? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return try? JSONDecoder().decode(CodexAuth.self, from: data)
    }

    /// Save the current auth.json as a named snapshot for `accountID`.
    @discardableResult
    func snapshotCurrent(accountID: String) -> String? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return snapshot(data: data, accountID: accountID)
    }

    /// Validate-independent snapshot write used by current-login and file import.
    ///
    /// - Parameters:
    ///   - data: Already validated Codex credential JSON.
    ///   - accountID: Provider identity used only to derive a safe filename.
    /// - Returns: Managed snapshot filename, or `nil` when the secure write fails.
    @discardableResult
    func snapshot(data: Data, accountID: String) -> String? {
        // Account IDs come from a local JWT. Hashing keeps untrusted path
        // separators out of the Application Support destination.
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let filename =
            "codex-"
            + digest.prefix(12)
            .map { String(format: "%02x", $0) }
            .joined() + ".json"
        let dest = snapshotsDir.appendingPathComponent(filename)
        do {
            try SecureFileWriter.write(data, to: dest)
            return filename
        } catch {
            return nil
        }
    }

    /// Permanently remove one managed snapshot after UI confirmation.
    /// The live `~/.codex/auth.json` file is never touched.
    func removeSnapshot(_ filename: String) -> Bool {
        guard let url = snapshotURL(for: filename) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    /// Read a saved snapshot into a CodexAuth (without activating it).
    func loadSnapshot(_ filename: String) -> CodexAuth? {
        guard let url = snapshotURL(for: filename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexAuth.self, from: data)
    }

    /// Make a snapshot the active `~/.codex/auth.json`.
    /// Backs up whatever is currently active first.
    @discardableResult
    func activate(snapshot filename: String) -> Bool {
        guard let src = snapshotURL(for: filename) else { return false }
        guard let data = try? Data(contentsOf: src) else { return false }
        // Back up the live file so a bad swap is recoverable.
        if let live = try? Data(contentsOf: authURL) {
            try? SecureFileWriter.write(
                live,
                to: authURL.appendingPathExtension("switcher-bak")
            )
        }
        do {
            try SecureFileWriter.write(data, to: authURL)
            return true
        } catch {
            return false
        }
    }

    /// List all saved snapshot filenames.
    func allSnapshots() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path))?
            .filter { $0.hasSuffix(".json") } ?? []
    }

    /// Resolve a persisted filename only when it remains inside the managed directory.
    private func snapshotURL(for filename: String) -> URL? {
        guard !filename.isEmpty,
            filename == URL(fileURLWithPath: filename).lastPathComponent
        else { return nil }
        let directory = snapshotsDir.standardizedFileURL
        let candidate = directory.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return nil }
        return candidate
    }
}
