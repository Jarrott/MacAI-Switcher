import CryptoKit
import Foundation

/// Parsed contents of a Codex `~/.codex/auth.json` file.
struct CodexAuth: Codable, Equatable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: Tokens?
    var lastRefresh: String?
    /// Snapshot-only recovery marker; never written to the CLI credential.
    var previousCredentialFingerprint: String?

    struct Tokens: Codable, Equatable {
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
        case previousCredentialFingerprint = "aiSwitcherPreviousCredentialFingerprint"
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

    let authURL: URL

    /// Directory where per-account credential snapshots are kept.
    let snapshotsDir: URL
    private let recoveryLock = NSRecursiveLock()

    /// Override paths only for isolated tests; production uses the standard CLI and app directories.
    init(authURL: URL? = nil, snapshotsDir: URL? = nil) {
        self.authURL =
            authURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let support =
            snapshotsDir
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher/codex-accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        self.snapshotsDir = support
    }

    /// The credential file currently active on disk, if any.
    func currentAuth() -> CodexAuth? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return try? JSONDecoder().decode(CodexAuth.self, from: data)
    }

    /// Snapshot the requested live identity, first repairing any previously saved rotation.
    /// Returns nil on identity/storage failure; never overwrites a saved successor with its predecessor.
    @discardableResult
    func snapshotCurrent(accountID: String) -> String? {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        let filename = Self.snapshotFilename(accountID: accountID)
        let account = Account(
            provider: .codex, label: "Codex", plan: .unknown, accountID: accountID,
            credentialSnapshot: filename)
        guard currentAuth()?.accountID == accountID,
            (try? auth(for: account)) != nil,
            let data = try? Data(contentsOf: authURL),
            let live = try? JSONDecoder().decode(CodexAuth.self, from: data),
            live.accountID == accountID
        else { return nil }
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
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        let filename = Self.snapshotFilename(accountID: accountID)
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
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
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
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard let src = snapshotURL(for: filename) else { return false }
        guard let stored = try? Data(contentsOf: src),
            let data = try? liveData(stored)
        else { return false }
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

    /// Load only this account's credential, adopting a matching live CLI rotation before any request.
    /// - Parameter account: Managed Codex identity and optional snapshot filename.
    /// - Returns: Latest credential verified against the managed account ID.
    /// - Throws: Missing credentials, unsafe path, or secure-storage failures.
    /// - Side effects: Synchronizes the snapshot, or repairs a prior failed live rotation write.
    func auth(for account: Account) throws -> CodexAuth {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard account.provider == .codex, let accountID = account.accountID, !accountID.isEmpty
        else {
            throw CodexAuthError.missingCredentials
        }
        let destination: URL?
        if let filename = account.credentialSnapshot {
            guard let url = snapshotURL(for: filename) else {
                throw CodexAuthError.missingCredentials
            }
            destination = url
        } else {
            destination = nil
        }
        let saved = account.credentialSnapshot.flatMap(loadSnapshot)
        let liveBytes = try? Data(contentsOf: authURL)
        let live = liveBytes.flatMap { try? JSONDecoder().decode(CodexAuth.self, from: $0) }
        if let live, live.accountID == accountID, live.tokens?.accessToken?.isEmpty == false {
            if let saved, saved.accountID == accountID, saved.tokens != live.tokens,
                saved.tokens?.accessToken?.isEmpty == false,
                saved.previousCredentialFingerprint == Self.fingerprint(live),
                let destination
            {
                // A previous exchange reached the snapshot but not auth.json. Never regress
                // to the retired live refresh token; retry the secure live write instead.
                do { try writeLive(Data(contentsOf: destination), replacing: live) } catch {
                    throw CodexAuthError.persistence
                }
                return saved
            }
            if let destination, let liveBytes, saved?.tokens != live.tokens {
                do { try SecureFileWriter.write(liveBytes, to: destination) } catch {
                    throw CodexAuthError.persistence
                }
            }
            return live
        }
        guard let saved, saved.accountID == accountID, saved.tokens?.accessToken?.isEmpty == false
        else {
            throw CodexAuthError.missingCredentials
        }
        return saved
    }

    /// Persist a successful exchange before its tokens can be used for provider requests.
    /// - Parameters: `base` is the exchanged generation; `updated` holds its successor;
    ///   `account` selects the validated managed destination.
    /// - Throws: Credential conflicts or persistence failures; neither is hidden as a 401.
    /// - Side effects: Saves owner-only JSON preserving unknown provider fields, then updates
    ///   the live file only if it still holds `base`. Other accounts are never overwritten.
    func persistRefreshedAuth(base: CodexAuth, updated: CodexAuth, for account: Account) throws {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard let accountID = account.accountID, base.accountID == accountID,
            updated.accountID == accountID
        else { throw CodexAuthError.credentialChanged }
        let destination: URL
        if let filename = account.credentialSnapshot {
            guard let url = snapshotURL(for: filename) else {
                throw CodexAuthError.missingCredentials
            }
            destination = url
        } else {
            destination = authURL
        }
        guard let original = try? Data(contentsOf: destination),
            let stored = try? JSONDecoder().decode(CodexAuth.self, from: original),
            Self.fingerprint(stored) == Self.fingerprint(base)
        else { throw CodexAuthError.credentialChanged }
        let live = currentAuth()
        if let live, live.accountID == accountID, Self.fingerprint(live) != Self.fingerprint(base) {
            throw CodexAuthError.credentialChanged
        }
        do {
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                var tokens = object["tokens"] as? [String: Any]
            else { throw CodexAuthError.persistence }
            tokens["access_token"] = updated.tokens?.accessToken
            tokens["refresh_token"] = updated.tokens?.refreshToken
            tokens["id_token"] = updated.tokens?.idToken
            object["tokens"] = tokens
            object["last_refresh"] = updated.lastRefresh
            object["aiSwitcherPreviousCredentialFingerprint"] = Self.fingerprint(base)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if destination == authURL {
                try writeLive(data, replacing: base)
            } else {
                try SecureFileWriter.write(data, to: destination)
                if let live, Self.fingerprint(live) == Self.fingerprint(base) {
                    try writeLive(data, replacing: base)
                }
            }
        } catch { throw CodexAuthError.persistence }
    }

    /// Non-secret generation digest used only for equality and failed-write recovery.
    static func fingerprint(_ auth: CodexAuth) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(auth.tokens)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash untrusted provider identities so they cannot introduce path components into storage.
    private static func snapshotFilename(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        return "codex-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Strip app-only metadata while preserving unmodeled provider fields for CLI compatibility.
    private func liveData(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.persistence
        }
        object.removeValue(forKey: "aiSwitcherPreviousCredentialFingerprint")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Recheck the expected generation and back it up before an atomic owner-only live write.
    /// An observed external switch fails closed; no cross-process transaction is available with the CLI.
    private func writeLive(_ data: Data, replacing expected: CodexAuth) throws {
        let sanitized = try liveData(data)
        let current = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(CodexAuth.self, from: current)
        guard Self.fingerprint(auth) == Self.fingerprint(expected) else {
            throw CodexAuthError.credentialChanged
        }
        try SecureFileWriter.write(current, to: authURL.appendingPathExtension("switcher-bak"))
        try SecureFileWriter.write(sanitized, to: authURL)
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
