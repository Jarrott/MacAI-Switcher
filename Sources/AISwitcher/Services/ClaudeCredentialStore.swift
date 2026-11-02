import CryptoKit
import Foundation

/// Parsed contents of the Claude Code OAuth credential blob.
struct ClaudeAuth: Codable, Sendable {
    var oauth: OAuth?
    var previousCredentialFingerprint: String?
    /// Managed identity resolved from Claude Code; absent from live credentials.
    var accountIdentity: ClaudeAccountIdentity?

    struct OAuth: Codable, Sendable {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Double?  // unix ms
        var scopes: [String]?
        var subscriptionType: String?
        var rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case accessToken, refreshToken, expiresAt, scopes
            case subscriptionType, rateLimitTier
        }
    }

    enum CodingKeys: String, CodingKey {
        case oauth = "claudeAiOauth"
        case previousCredentialFingerprint = "aiSwitcherPreviousCredentialFingerprint"
        case accountIdentity = "aiSwitcherAccountIdentity"
    }

    var planType: String? { oauth?.subscriptionType }
    var accessToken: String? { oauth?.accessToken }

    /// OAuth access-token expiry converted from Claude Code's Unix milliseconds.
    var accessTokenExpiry: Date? {
        guard let milliseconds = oauth?.expiresAt, milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

/// Reads Claude Code credentials from the macOS Keychain (with a
/// `~/.claude/.credentials.json` file fallback), plus per-account snapshots.
final class ClaudeCredentialStore: Sendable {
    static let shared = ClaudeCredentialStore()

    let snapshotsDir: URL
    private let fileURL: URL
    private let readKeychain: (@Sendable () -> Data?)?
    private let saveKeychain: (@Sendable (Data) -> Bool)?
    private let profiles: ClaudeProfileStore

    /// Configure storage; overrides isolate tests from the user's Keychain and credentials.
    init(
        snapshotsDir: URL? = nil,
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"),
        readKeychain: (@Sendable () -> Data?)? = nil,
        saveKeychain: (@Sendable (Data) -> Bool)? = nil,
        profiles: ClaudeProfileStore = .shared
    ) {
        self.fileURL = fileURL
        self.readKeychain = readKeychain
        self.saveKeychain = saveKeychain
        self.profiles = profiles
        let support =
            snapshotsDir
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher/claude-accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        self.snapshotsDir = support
    }

    // MARK: Live credential

    /// Raw JSON currently active (Keychain first, then file).
    func liveData() -> Data? {
        if let d = keychainData() { return d }
        return try? Data(contentsOf: fileURL)
    }

    func currentAuth() -> ClaudeAuth? {
        guard let d = liveData() else { return nil }
        return try? JSONDecoder().decode(ClaudeAuth.self, from: d)
    }

    /// Resolve one managed credential and synchronize a provably related live rotation.
    /// - Parameter account: Account whose snapshot owns the request.
    /// - Returns: Latest related credential. Missing snapshots never fall back to another login.
    /// - Throws: Sanitized read/write errors. A failed live write can be retried from the snapshot.
    /// - Side effects: Saves newer live tokens, or repairs an older live copy after a failed write.
    func auth(for account: Account) throws -> ClaudeAuth {
        guard let filename = account.credentialSnapshot,
            let url = snapshotURL(for: filename),
            let saved = loadSnapshot(filename),
            let access = saved.accessToken, !access.isEmpty
        else { throw ClaudeAuthError.missingCredentials }
        guard let liveData = liveData(),
            let live = try? JSONDecoder().decode(ClaudeAuth.self, from: liveData)
        else { return saved }
        if let previous = saved.previousCredentialFingerprint,
            previous == Self.fingerprint(live)
        {
            let data = try mergingOAuth(saved, into: liveData, managed: .stripped)
            try writeLiveData(data, replacing: live)
            return saved
        }
        guard Self.sharesCredential(saved, live) else {
            return try adoptingRotatedLive(live, data: liveData, saved: saved, url: url)
        }
        let liveIsNewer =
            (live.accessTokenExpiry ?? .distantPast) > (saved.accessTokenExpiry ?? .distantPast)
        if liveIsNewer {
            return try adoptLive(live, data: liveData, identity: saved.accountIdentity, url: url)
        }
        return saved
    }

    /// Follow a token rotation Claude Code performed outside the switcher.
    ///
    /// Claude rotates both tokens on every refresh, so a token mismatch alone is
    /// not evidence of a different login. Only the CLI's recorded account identity
    /// can tell a rotation apart from a different account, and it is trusted only
    /// while no managed snapshot already owns the live credential — right after the
    /// switcher activates a snapshot, the CLI's record still describes the account
    /// it replaced.
    /// - Returns: The newer live generation when it provably belongs to this
    ///   account, otherwise the unchanged snapshot.
    /// - Throws: `persistence` when the adopted generation cannot be saved.
    /// - Side effects: Saves the rotated credential into this account's snapshot,
    ///   so its superseded refresh token is never presented to the provider again.
    private func adoptingRotatedLive(
        _ live: ClaudeAuth, data: Data, saved: ClaudeAuth, url: URL
    ) throws -> ClaudeAuth {
        guard let identity = saved.accountIdentity,
            snapshotOwning(live) == nil,
            profiles.liveIdentity()?.accountUUID == identity.accountUUID
        else { return saved }
        return try adoptLive(live, data: data, identity: identity, url: url)
    }

    /// Store a live credential generation as this account's snapshot.
    /// Live credentials never carry managed metadata, so the resolved identity is
    /// reattached instead of being dropped with the superseded generation.
    private func adoptLive(
        _ live: ClaudeAuth, data: Data, identity: ClaudeAccountIdentity?, url: URL
    ) throws -> ClaudeAuth {
        let merged = try mergingOAuth(
            live, into: data, managed: ManagedFields(identity: identity))
        do { try SecureFileWriter.write(merged, to: url) } catch {
            throw ClaudeAuthError.persistence
        }
        var adopted = live
        adopted.previousCredentialFingerprint = nil
        adopted.accountIdentity = identity
        return adopted
    }

    /// The managed snapshot whose OAuth tokens the live credential already matches.
    /// A match proves the switcher, not Claude Code, produced the live credential.
    private func snapshotOwning(_ live: ClaudeAuth) -> String? {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []
        return names.sorted().first { name in
            guard name.hasSuffix(".json"), let candidate = loadSnapshot(name) else { return false }
            return Self.sharesCredential(candidate, live)
        }
    }

    /// Identify a credential generation without storing or logging additional token material.
    static func fingerprint(_ auth: ClaudeAuth) -> String? {
        guard let access = auth.accessToken, !access.isEmpty else { return nil }
        let seed = access + "\n" + (auth.oauth?.refreshToken ?? "")
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Token continuity is evidence of ownership; account labels and active checkmarks are not.
    static func sharesCredential(_ lhs: ClaudeAuth, _ rhs: ClaudeAuth) -> Bool {
        if let access = lhs.accessToken, !access.isEmpty, access == rhs.accessToken { return true }
        if let refresh = lhs.oauth?.refreshToken, !refresh.isEmpty,
            refresh == rhs.oauth?.refreshToken
        {
            return true
        }
        return false
    }

    /// Resolve the managed identifier for one Claude credential.
    ///
    /// - Parameter auth: Parsed Claude credential.
    /// - Returns: The account's stable identifier, or `nil` without OAuth material.
    ///
    /// Claude rotates both tokens on every refresh, so a token-derived identifier
    /// changes under an unchanged account and makes the same login look like a new
    /// one. A resolved account identity is therefore always preferred; the token
    /// digest survives only as a last resort for credentials Claude Code has not
    /// recorded. The raw token is never returned, stored in the identifier, or logged.
    func stableAccountID(for auth: ClaudeAuth) -> String? {
        if let identity = auth.accountIdentity { return identity.accountID }
        guard let seed = auth.oauth?.refreshToken ?? auth.accessToken else { return nil }
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "claude-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// One Claude login resolved from the credential that is live on this Mac.
    struct LiveAccount: Sendable {
        let auth: ClaudeAuth
        let accountID: String
        let snapshot: String?
    }

    /// Identify and back up the Claude login that is currently live.
    ///
    /// - Returns: The live credential with its resolved identity, or `nil` when no
    ///   usable login exists.
    /// - Side effects: Writes an owner-only snapshot named after the resolved
    ///   account, so the live generation survives a later account switch.
    ///
    /// Identity is resolved from the snapshot that already owns the live tokens,
    /// because the switcher wrote it and knows whose it is. Only when no snapshot
    /// owns them did Claude Code produce this credential, and its recorded identity
    /// becomes authoritative. An owning snapshot also keeps its existing identifier,
    /// so a rotation the switcher itself observed never renames the account.
    func resolveLiveAccount() -> LiveAccount? {
        guard let data = liveData(),
            var live = try? JSONDecoder().decode(ClaudeAuth.self, from: data),
            let access = live.accessToken, !access.isEmpty
        else { return nil }
        let owner = snapshotOwning(live)
        if let owner {
            live.accountIdentity = loadSnapshot(owner)?.accountIdentity
        } else {
            live.accountIdentity = profiles.liveIdentity()
        }
        guard
            let accountID = live.accountIdentity?.accountID
                ?? owner.map({ String($0.dropLast(".json".count)) })
                ?? stableAccountID(for: live)
        else { return nil }
        let merged = try? mergingOAuth(
            live, into: data, managed: ManagedFields(identity: live.accountIdentity))
        let filename = merged.flatMap { snapshot(data: $0, accountID: accountID) }
        return LiveAccount(auth: live, accountID: accountID, snapshot: filename)
    }

    /// Non-secret identifier of the credential generation a snapshot currently holds.
    /// Callers use it to notice that a rejected credential has since been replaced.
    func snapshotFingerprint(_ filename: String?) -> String? {
        guard let filename, let auth = loadSnapshot(filename) else { return nil }
        return Self.fingerprint(auth)
    }

    /// Read the live Keychain through permission preflight, or an isolated test override.
    /// Returns nil for unavailable access; never displays or logs credential contents.
    private func keychainData() -> Data? {
        if let readKeychain { return readKeychain() }
        return ClaudeKeychainStore.read()
    }

    // MARK: Snapshots

    /// Compare two snapshots by OAuth token to migrate identifiers created by
    /// older builds that used Swift's process-randomized `hashValue`.
    func snapshotsContainSameAccount(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs,
            let lhsAuth = loadSnapshot(lhs),
            let rhsAuth = loadSnapshot(rhs),
            let lhsToken = lhsAuth.accessToken,
            let rhsToken = rhsAuth.accessToken
        else { return false }
        return lhsToken == rhsToken
    }

    @discardableResult
    func snapshotCurrent(accountID: String) -> String? {
        guard let data = liveData() else { return nil }
        return snapshot(data: data, accountID: accountID)
    }

    /// Store an already validated Claude credential as an owner-only snapshot.
    ///
    /// - Parameters:
    ///   - data: Claude credential JSON.
    ///   - accountID: Deterministic credential identifier used for the filename.
    /// - Returns: Managed filename, or `nil` when persistence fails.
    @discardableResult
    func snapshot(data: Data, accountID: String) -> String? {
        let filename = "\(accountID).json"
        let dest = snapshotsDir.appendingPathComponent(filename)
        do {
            try SecureFileWriter.write(data, to: dest)
            return filename
        } catch {
            return nil
        }
    }

    /// Permanently remove one inactive managed snapshot after UI confirmation.
    /// Keychain and the live Claude fallback file remain unchanged.
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

    /// Persist a rotated credential before exposing its access token to usage requests.
    /// - Parameters: `base` is the generation exchanged; `updated` contains new OAuth fields;
    ///   `snapshot` is the owned managed filename.
    /// - Throws: A sanitized storage/conflict error when a changed generation is observed.
    /// - Side effects: Atomically saves the snapshot first, then updates only matching live tokens.
    ///   Unknown provider JSON fields survive. A generation fingerprint allows a failed live write
    ///   to be retried on the next read without exchanging the refresh token again.
    func persistRefreshedAuth(base: ClaudeAuth, updated: ClaudeAuth, snapshot: String?) throws {
        guard let snapshot, let url = snapshotURL(for: snapshot),
            let raw = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode(ClaudeAuth.self, from: raw)
        else { throw ClaudeAuthError.persistence }
        guard Self.fingerprint(saved) == Self.fingerprint(base) else {
            throw ClaudeAuthError.credentialChanged
        }
        let data = try mergingOAuth(
            updated, into: raw,
            managed: ManagedFields(
                previousFingerprint: Self.fingerprint(base), identity: saved.accountIdentity))
        do { try SecureFileWriter.write(data, to: url) } catch { throw ClaudeAuthError.persistence }
        if let liveRaw = liveData(),
            let live = try? JSONDecoder().decode(ClaudeAuth.self, from: liveRaw),
            Self.fingerprint(live) == Self.fingerprint(base)
        {
            let liveUpdated = try mergingOAuth(updated, into: liveRaw, managed: .stripped)
            try writeLiveData(liveUpdated, replacing: live)
        }
    }

    /// Switcher-owned metadata stored beside the provider's own credential JSON.
    /// It belongs only in owner-only snapshots and is stripped from every live write,
    /// so Claude Code always reads back exactly the shape it wrote.
    private struct ManagedFields {
        var previousFingerprint: String?
        var identity: ClaudeAccountIdentity?

        /// Carries no managed metadata; used for credentials handed to Claude Code.
        static let stripped = ManagedFields()
    }

    /// Merge the owned OAuth fields into a provider blob, preserving unknown CLI metadata.
    /// Throws a sanitized error for malformed JSON; never includes provider contents in errors.
    private func mergingOAuth(
        _ auth: ClaudeAuth, into raw: Data, managed: ManagedFields
    ) throws -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            var oauth = object["claudeAiOauth"] as? [String: Any],
            let encoded = try? JSONEncoder().encode(auth.oauth),
            let fields = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { throw ClaudeAuthError.persistence }
        oauth.removeValue(forKey: "expiresAt")
        oauth.merge(fields) { _, new in new }
        object["claudeAiOauth"] = oauth
        object["aiSwitcherPreviousCredentialFingerprint"] = managed.previousFingerprint
        object["aiSwitcherAccountIdentity"] = try managed.identity.map { identity in
            guard let encoded = try? JSONEncoder().encode(identity),
                let fields = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { throw ClaudeAuthError.persistence }
            return fields
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ClaudeAuthError.persistence
        }
        return data
    }

    /// Activate a snapshot in Keychain, then mirror the file fallback without recovery metadata.
    /// - Parameter filename: Managed credential snapshot to activate.
    /// - Returns: False on invalid JSON or denied Keychain access; a fallback file alone
    ///   cannot switch the macOS CLI, which prefers Keychain. File mirroring is best effort.
    /// - Side effects: Writes live credentials only after the Keychain accepts the switch.
    @discardableResult
    func activate(snapshot filename: String) -> Bool {
        guard let src = snapshotURL(for: filename) else { return false }
        guard let raw = try? Data(contentsOf: src),
            let auth = try? JSONDecoder().decode(ClaudeAuth.self, from: raw),
            let data = try? mergingOAuth(auth, into: raw, managed: .stripped)
        else { return false }
        guard writeKeychain(data) else { return false }
        // Keep fallback readers synchronized after the authoritative store succeeds.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SecureFileWriter.write(data, to: fileURL)
        return true
    }

    private func loadSnapshot(_ filename: String) -> ClaudeAuth? {
        guard let url = snapshotURL(for: filename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeAuth.self, from: data)
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

    /// Update the authoritative live store without treating a fallback write as Keychain success.
    /// Throws on persistence failure; callers retain the rotated snapshot for recovery.
    private func writeLiveData(_ data: Data, replacing expected: ClaudeAuth) throws {
        guard let expectedFingerprint = Self.fingerprint(expected) else {
            throw ClaudeAuthError.credentialChanged
        }
        if let keychainRaw = keychainData() {
            guard let current = try? JSONDecoder().decode(ClaudeAuth.self, from: keychainRaw),
                Self.fingerprint(current) == expectedFingerprint
            else { throw ClaudeAuthError.credentialChanged }
            guard writeKeychain(data) else { throw ClaudeAuthError.persistence }
            // Mirror only an existing fallback that belongs to the generation just replaced.
            guard let fileRaw = try? Data(contentsOf: fileURL),
                let fileAuth = try? JSONDecoder().decode(ClaudeAuth.self, from: fileRaw),
                let keychainAuth = try? JSONDecoder().decode(ClaudeAuth.self, from: keychainRaw),
                let fingerprint = Self.fingerprint(keychainAuth),
                fingerprint == Self.fingerprint(fileAuth)
            else { return }
            guard let updated = try? JSONDecoder().decode(ClaudeAuth.self, from: data) else {
                throw ClaudeAuthError.persistence
            }
            let merged = try mergingOAuth(updated, into: fileRaw, managed: .stripped)
            do { try SecureFileWriter.write(merged, to: fileURL) } catch {
                throw ClaudeAuthError.persistence
            }
            return
        }
        guard let currentRaw = try? Data(contentsOf: fileURL),
            let current = try? JSONDecoder().decode(ClaudeAuth.self, from: currentRaw)
        else { throw ClaudeAuthError.persistence }
        guard Self.fingerprint(current) == expectedFingerprint else {
            throw ClaudeAuthError.credentialChanged
        }
        do { try SecureFileWriter.write(data, to: fileURL) } catch {
            throw ClaudeAuthError.persistence
        }
    }

    /// Write credential bytes through Claude's system writer to preserve reader compatibility.
    /// - Parameter data: Validated Claude credential JSON; never logged.
    /// - Returns: False if the CLI has not initialized its item or access is denied.
    /// - Side effects: Updates the live Keychain bytes through the system writer.
    ///   Native updates rebind partition ACLs to the calling app and must not be used.
    private func writeKeychain(_ data: Data) -> Bool {
        if let saveKeychain { return saveKeychain(data) }
        return ClaudeKeychainStore.update(data)
    }
}
