import CryptoKit
import Foundation

/// Parsed contents of a Gemini CLI `~/.gemini/oauth_creds.json` file.
struct GeminiAuth: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var scope: String?
    var tokenType: String?
    var expiryDate: Double?  // unix ms (as written by google-auth-library / gemini-cli)
    /// Optional OAuth client credentials if bundled inside an imported JSON file.
    var clientID: String?
    var clientSecret: String?
    /// Snapshot-only recovery marker; never written to the CLI credential.
    var previousCredentialFingerprint: String?
    /// Snapshot-only identity cache resolved from `google_accounts.json` or JWT.
    var accountEmail: String?
    var accountSub: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
        case tokenType = "token_type"
        case expiryDate = "expiry_date"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case previousCredentialFingerprint = "aiSwitcherPreviousCredentialFingerprint"
        case accountEmail = "aiSwitcherAccountEmail"
        case accountSub = "aiSwitcherAccountSub"
    }

    // MARK: Derived identity from id_token JWT or cached account record

    private var idClaims: [String: Any]? {
        guard let token = idToken, !token.isEmpty else { return nil }
        return JWT.claims(token)
    }

    var email: String? {
        if let claim = idClaims?["email"] as? String, !claim.isEmpty { return claim }
        if let cached = accountEmail, !cached.isEmpty { return cached }
        return nil
    }

    var name: String? {
        guard let claim = idClaims?["name"] as? String, !claim.isEmpty else { return nil }
        return claim
    }

    var subject: String? {
        if let claim = idClaims?["sub"] as? String, !claim.isEmpty { return claim }
        if let cached = accountSub, !cached.isEmpty { return cached }
        return nil
    }

    /// Stable account identifier that survives access-token refreshes.
    var stableAccountID: String? {
        if let subject, !subject.isEmpty { return "gemini-" + subject }
        if let email, !email.isEmpty { return "gemini-" + email.lowercased() }
        guard let seed = nonEmpty(refreshToken) ?? nonEmpty(accessToken) else { return nil }
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "gemini-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Access-token expiry converted from Unix milliseconds (or seconds fallback).
    var accessTokenExpiry: Date? {
        guard let raw = expiryDate, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Shape of Gemini CLI's `~/.gemini/google_accounts.json` tracking file.
private struct GeminiAccountsRecord: Codable {
    var active: String?
    var old: [String]?
}

/// Reads, snapshots, and swaps the Gemini CLI OAuth credential file (`~/.gemini/oauth_creds.json`).
final class GeminiCredentialStore: Sendable {
    static let shared = GeminiCredentialStore()

    let authURL: URL
    let accountsFileURL: URL
    let snapshotsDir: URL
    private let recoveryLock = NSRecursiveLock()

    /// One Gemini login resolved from the credential that is currently live.
    struct LiveAccount: Sendable {
        let auth: GeminiAuth
        let accountID: String
        let snapshot: String?
    }

    /// Override paths only for isolated tests; production uses standard CLI and app directories.
    init(
        authURL: URL? = nil,
        accountsFileURL: URL? = nil,
        snapshotsDir: URL? = nil
    ) {
        let geminiDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
        self.authURL = authURL ?? geminiDir.appendingPathComponent("oauth_creds.json")
        self.accountsFileURL =
            accountsFileURL ?? geminiDir.appendingPathComponent("google_accounts.json")
        let support =
            snapshotsDir
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher/gemini-accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        self.snapshotsDir = support
    }

    /// The credential file currently active on disk, if any.
    func currentAuth() -> GeminiAuth? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return try? JSONDecoder().decode(GeminiAuth.self, from: data)
    }

    /// Active Google email recorded by Gemini CLI in `google_accounts.json`, if present.
    func liveRecordedEmail() -> String? {
        guard let data = try? Data(contentsOf: accountsFileURL),
            let record = try? JSONDecoder().decode(GeminiAccountsRecord.self, from: data),
            let active = record.active?.trimmingCharacters(in: .whitespacesAndNewlines),
            !active.isEmpty
        else { return nil }
        return active
    }

    /// Identify and back up the Gemini login that is currently live.
    func resolveLiveAccount() -> LiveAccount? {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard let raw = try? Data(contentsOf: authURL),
            var live = try? JSONDecoder().decode(GeminiAuth.self, from: raw),
            let access = live.accessToken, !access.isEmpty
        else { return nil }

        let owner = snapshotOwning(live)
        if let owner, let saved = loadSnapshot(owner) {
            // If an existing managed snapshot already owns the live tokens, prefer its identity
            // metadata and repair any previously unsaved rotation before writing back.
            if saved.previousCredentialFingerprint == Self.fingerprint(live),
                let savedAccess = saved.accessToken, !savedAccess.isEmpty
            {
                if let url = snapshotURL(for: owner), let savedBytes = try? Data(contentsOf: url) {
                    try? writeLive(savedBytes, replacing: live)
                }
                live = saved
            } else {
                live.accountEmail = live.email ?? saved.email
                live.accountSub = live.subject ?? saved.subject
            }
        } else {
            live.accountEmail = live.email ?? liveRecordedEmail()
            live.accountSub = live.subject
        }

        guard let accountID = live.stableAccountID else { return nil }
        let snapshotData = (try? embeddingManagedFields(live, into: raw)) ?? raw
        let filename = snapshot(data: snapshotData, accountID: accountID)
        return LiveAccount(auth: live, accountID: accountID, snapshot: filename)
    }

    /// Store an already validated Gemini credential as an owner-only snapshot.
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

    /// Permanently remove one managed snapshot; never touches live `~/.gemini/oauth_creds.json`.
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

    /// Read a saved snapshot into a `GeminiAuth` without activating it.
    func loadSnapshot(_ filename: String) -> GeminiAuth? {
        guard let url = snapshotURL(for: filename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GeminiAuth.self, from: data)
    }

    /// Non-secret identifier of the credential generation a snapshot currently holds.
    func snapshotFingerprint(_ filename: String?) -> String? {
        guard let filename, let auth = loadSnapshot(filename) else { return nil }
        return Self.fingerprint(auth)
    }

    /// Make a snapshot the active `~/.gemini/oauth_creds.json`, backing up any live file first.
    @discardableResult
    func activate(snapshot filename: String) -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard let src = snapshotURL(for: filename),
            let stored = try? Data(contentsOf: src),
            let parsed = try? JSONDecoder().decode(GeminiAuth.self, from: stored),
            let data = try? liveData(stored)
        else { return false }

        do {
            try FileManager.default.createDirectory(
                at: authURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let live = try? Data(contentsOf: authURL) {
                try? SecureFileWriter.write(
                    live,
                    to: authURL.appendingPathExtension("switcher-bak")
                )
            }
            try SecureFileWriter.write(data, to: authURL)
        } catch {
            return false
        }

        if let email = parsed.email, !email.isEmpty {
            updateRecordedActiveEmail(email)
        }
        return true
    }

    /// Load only this account's credential, adopting a matching live CLI rotation before any request.
    func auth(for account: Account) throws -> GeminiAuth {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard account.provider == .gemini,
            let accountID = account.accountID, !accountID.isEmpty,
            let filename = account.credentialSnapshot,
            let destination = snapshotURL(for: filename),
            let saved = loadSnapshot(filename),
            let savedAccess = saved.accessToken, !savedAccess.isEmpty
        else {
            throw GeminiAuthError.missingCredentials
        }

        guard let liveBytes = try? Data(contentsOf: authURL),
            var live = try? JSONDecoder().decode(GeminiAuth.self, from: liveBytes),
            let liveAccess = live.accessToken, !liveAccess.isEmpty
        else {
            return saved
        }

        // Repair a prior exchange that reached the snapshot before the live write completed.
        if let previous = saved.previousCredentialFingerprint,
            previous == Self.fingerprint(live)
        {
            do {
                try writeLive(Data(contentsOf: destination), replacing: live)
            } catch {
                throw GeminiAuthError.persistence
            }
            return saved
        }

        guard matchesAccount(live, saved: saved, accountID: accountID) else {
            return saved
        }

        live.accountEmail = live.email ?? saved.email
        live.accountSub = live.subject ?? saved.subject
        let liveIsNewer =
            (live.accessTokenExpiry ?? .distantPast) > (saved.accessTokenExpiry ?? .distantPast)
        let tokenChanged = Self.fingerprint(live) != Self.fingerprint(saved)
        if tokenChanged && (liveIsNewer || saved.accessTokenExpiry == nil) {
            do {
                let merged = try embeddingManagedFields(
                    live, into: liveBytes, previousFingerprint: nil)
                try SecureFileWriter.write(merged, to: destination)
            } catch {
                throw GeminiAuthError.persistence
            }
            return live
        }
        return saved
    }

    /// Persist a refreshed credential atomically before its access token is used.
    func persistRefreshedAuth(base: GeminiAuth, updated: GeminiAuth, for account: Account) throws {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard account.provider == .gemini,
            let filename = account.credentialSnapshot,
            let destination = snapshotURL(for: filename),
            let original = try? Data(contentsOf: destination),
            let stored = try? JSONDecoder().decode(GeminiAuth.self, from: original),
            Self.fingerprint(stored) == Self.fingerprint(base)
        else {
            throw GeminiAuthError.credentialChanged
        }

        let live = currentAuth()
        if let live,
            let accountID = account.accountID,
            matchesAccount(live, saved: stored, accountID: accountID),
            Self.fingerprint(live) != Self.fingerprint(base)
        {
            throw GeminiAuthError.credentialChanged
        }

        do {
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
            else {
                throw GeminiAuthError.persistence
            }
            object["access_token"] = updated.accessToken
            if let refresh = updated.refreshToken { object["refresh_token"] = refresh }
            if let idToken = updated.idToken { object["id_token"] = idToken }
            if let scope = updated.scope { object["scope"] = scope }
            if let tokenType = updated.tokenType { object["token_type"] = tokenType }
            if let expiryDate = updated.expiryDate {
                object["expiry_date"] = expiryDate
            } else {
                object.removeValue(forKey: "expiry_date")
            }
            object["aiSwitcherPreviousCredentialFingerprint"] = Self.fingerprint(base)
            if let email = updated.email ?? stored.email {
                object["aiSwitcherAccountEmail"] = email
            }
            if let sub = updated.subject ?? stored.subject {
                object["aiSwitcherAccountSub"] = sub
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try SecureFileWriter.write(data, to: destination)
            if let live, Self.fingerprint(live) == Self.fingerprint(base) {
                try writeLive(data, replacing: base)
            }
        } catch let error as GeminiAuthError {
            throw error
        } catch {
            throw GeminiAuthError.persistence
        }
    }

    /// Resolve a concise display label matching Codex/Claude conventions.
    static func preferredLabel(email: String?, name: String?) -> String {
        email?.components(separatedBy: "@").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? name?.components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? Provider.gemini.displayName
    }

    /// Non-secret generation digest used for equality and failed-write recovery.
    static func fingerprint(_ auth: GeminiAuth) -> String? {
        guard let access = auth.accessToken, !access.isEmpty else { return nil }
        let seed =
            access + "\n" + (auth.refreshToken ?? "") + "\n" + (auth.idToken ?? "")
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two Gemini credentials clearly represent the same login.
    static func sharesCredential(_ lhs: GeminiAuth, _ rhs: GeminiAuth) -> Bool {
        if let lhsSub = lhs.subject, !lhsSub.isEmpty, lhsSub == rhs.subject { return true }
        if let lhsEmail = lhs.email?.lowercased(), !lhsEmail.isEmpty,
            lhsEmail == rhs.email?.lowercased()
        {
            return true
        }
        if let lhsRefresh = lhs.refreshToken, !lhsRefresh.isEmpty,
            lhsRefresh == rhs.refreshToken
        {
            return true
        }
        if let lhsAccess = lhs.accessToken, !lhsAccess.isEmpty, lhsAccess == rhs.accessToken {
            return true
        }
        return false
    }

    // MARK: Internal helpers

    private func matchesAccount(
        _ live: GeminiAuth,
        saved: GeminiAuth,
        accountID: String
    ) -> Bool {
        if let liveSub = live.subject, let savedSub = saved.subject, !liveSub.isEmpty {
            return liveSub == savedSub
        }
        if let liveEmail = live.email?.lowercased(), let savedEmail = saved.email?.lowercased(),
            !liveEmail.isEmpty
        {
            return liveEmail == savedEmail
        }
        if live.stableAccountID == accountID { return true }
        if let liveRefresh = live.refreshToken, !liveRefresh.isEmpty,
            liveRefresh == saved.refreshToken
        {
            return true
        }
        if let liveAccess = live.accessToken, !liveAccess.isEmpty, liveAccess == saved.accessToken {
            return true
        }
        // Only consult google_accounts.json if no other managed snapshot already owns live tokens.
        if snapshotOwning(live) == nil,
            let recordedEmail = liveRecordedEmail()?.lowercased(),
            let savedEmail = saved.email?.lowercased(),
            recordedEmail == savedEmail
        {
            return true
        }
        return false
    }

    private func snapshotOwning(_ live: GeminiAuth) -> String? {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []
        return names.sorted().first { name in
            guard name.hasSuffix(".json"), let candidate = loadSnapshot(name) else { return false }
            return Self.sharesCredential(candidate, live)
        }
    }

    /// Hash untrusted provider identities so they cannot introduce path components into storage.
    private static func snapshotFilename(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        return "gemini-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func embeddingManagedFields(
        _ auth: GeminiAuth,
        into raw: Data,
        previousFingerprint: String? = nil
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GeminiAuthError.persistence
        }
        if let previousFingerprint {
            object["aiSwitcherPreviousCredentialFingerprint"] = previousFingerprint
        } else {
            object.removeValue(forKey: "aiSwitcherPreviousCredentialFingerprint")
        }
        if let email = auth.email { object["aiSwitcherAccountEmail"] = email }
        if let sub = auth.subject { object["aiSwitcherAccountSub"] = sub }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Strip app-only metadata while preserving unmodeled provider fields for CLI compatibility.
    private func liveData(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiAuthError.persistence
        }
        object.removeValue(forKey: "aiSwitcherPreviousCredentialFingerprint")
        object.removeValue(forKey: "aiSwitcherAccountEmail")
        object.removeValue(forKey: "aiSwitcherAccountSub")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Recheck the expected generation and back it up before an atomic owner-only live write.
    private func writeLive(_ data: Data, replacing expected: GeminiAuth) throws {
        let sanitized = try liveData(data)
        let current = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(GeminiAuth.self, from: current)
        guard Self.fingerprint(auth) == Self.fingerprint(expected) else {
            throw GeminiAuthError.credentialChanged
        }
        try SecureFileWriter.write(current, to: authURL.appendingPathExtension("switcher-bak"))
        try SecureFileWriter.write(sanitized, to: authURL)
    }

    /// Best-effort sync of Gemini CLI's `google_accounts.json` active email on account switch.
    private func updateRecordedActiveEmail(_ email: String) {
        var record =
            (try? Data(contentsOf: accountsFileURL))
            .flatMap { try? JSONDecoder().decode(GeminiAccountsRecord.self, from: $0) }
            ?? GeminiAccountsRecord(active: nil, old: [])
        var previous = record.old ?? []
        if let currentActive = record.active,
            !currentActive.isEmpty,
            currentActive.caseInsensitiveCompare(email) != .orderedSame,
            !previous.contains(where: { $0.caseInsensitiveCompare(currentActive) == .orderedSame })
        {
            previous.append(currentActive)
        }
        previous.removeAll { $0.caseInsensitiveCompare(email) == .orderedSame }
        record.active = email
        record.old = previous
        guard let encoded = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: accountsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? SecureFileWriter.write(encoded, to: accountsFileURL)
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
