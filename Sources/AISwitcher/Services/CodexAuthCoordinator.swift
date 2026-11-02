import CryptoKit
import Foundation

/// Shares Codex token exchanges across usage and reset requests; every operation has a bounded retry.
actor CodexAuthCoordinator {
    static let shared = CodexAuthCoordinator()
    private let store: CodexCredentialStore
    private let transport: TokenRefresher.Transport
    private var renewals: [String: Task<CodexAuth, Error>] = [:]
    private var rejectedRefreshTokens: [String: String] = [:]
    private struct Rotation {
        let base: CodexAuth
        let updated: CodexAuth
    }
    /// Retain successful exchanges until storage succeeds; never replay their old refresh token.
    private var pendingRotations: [String: Rotation] = [:]

    /// Inject isolated storage and HTTP for tests. Production never logs credential material.
    init(
        store: CodexCredentialStore = .shared,
        transport: @escaping TokenRefresher.Transport = TokenRefresher.send
    ) {
        self.store = store
        self.transport = transport
    }

    /// Authorize one request, reconciling live tokens first and retrying only one 401.
    /// - Parameters: `request` is a token-free template; `account` owns the credential.
    /// - Returns: Provider bytes, HTTP response and the credential used for follow-up reads.
    /// - Throws: Sanitized auth/storage failures; non-401 HTTP responses are left to the caller.
    /// - Side effects: At most one OAuth exchange per operation, persisted before use. A POST
    ///   retry keeps the exact same body and idempotency key. 403/429 never trigger renewal.
    func send(
        _ request: URLRequest, for account: Account
    ) async throws -> (Data, HTTPURLResponse, CodexAuth) {
        var auth = try currentAuth(for: account)
        var exchanged = false
        if let expiry = auth.accessTokenExpiry, expiry < Date().addingTimeInterval(60) {
            auth = try await renew(auth, for: account)
            exchanged = true
        }
        func authorized(_ auth: CodexAuth) -> URLRequest {
            var result = request
            result.setValue(
                "Bearer \(auth.tokens?.accessToken ?? "")", forHTTPHeaderField: "Authorization")
            result.setValue(auth.accountID, forHTTPHeaderField: "chatgpt-account-id")
            return result
        }
        var (data, response) = try await transport(authorized(auth))
        if response.statusCode == 401 {
            let latest = try currentAuth(for: account)
            if latest.tokens != auth.tokens {
                auth = latest
            } else if !exchanged {
                auth = try await renew(latest, for: account)
            } else {
                throw CodexAuthError.loginRequired
            }
            (data, response) = try await transport(authorized(auth))
        }
        guard response.statusCode != 401 else { throw CodexAuthError.loginRequired }
        return (data, response, auth)
    }

    /// Retry an unsaved exchange before another request, even if the old access token has not
    /// expired. A newer imported or CLI generation supersedes the in-memory rotation.
    private func currentAuth(for account: Account) throws -> CodexAuth {
        let auth = try store.auth(for: account)
        let key = account.accountID ?? account.id.uuidString
        guard let rotation = pendingRotations[key] else { return auth }
        if auth.tokens == rotation.base.tokens {
            try store.persistRefreshedAuth(base: auth, updated: rotation.updated, for: account)
            pendingRotations.removeValue(forKey: key)
            return rotation.updated
        }
        pendingRotations.removeValue(forKey: key)
        return auth
    }

    /// Exchange only the current generation; concurrent callers share the same durable result.
    /// A definitively rejected refresh token is held until it changes, while transient failures
    /// remain retryable. A CLI rotation observed during a failed exchange can recover the request.
    private func renew(_ base: CodexAuth, for account: Account) async throws -> CodexAuth {
        let latest = try currentAuth(for: account)
        if latest.tokens != base.tokens { return latest }
        let key = account.accountID ?? account.id.uuidString
        if let pending = renewals[key] { return try await pending.value }
        let refreshDigest = SHA256.hash(data: Data((base.tokens?.refreshToken ?? "").utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard rejectedRefreshTokens[key] != refreshDigest else {
            throw CodexAuthError.loginRequired
        }
        let store = self.store
        let transport = self.transport
        let task = Task {
            let updated = try await TokenRefresher.refreshCodex(auth: latest, transport: transport)
            pendingRotations[key] = Rotation(base: latest, updated: updated)
            try store.persistRefreshedAuth(base: latest, updated: updated, for: account)
            pendingRotations.removeValue(forKey: key)
            return updated
        }
        renewals[key] = task
        defer { renewals.removeValue(forKey: key) }
        do {
            let updated = try await task.value
            rejectedRefreshTokens.removeValue(forKey: key)
            return updated
        } catch {
            if let failure = error as? CodexAuthError {
                switch failure {
                case .persistence, .credentialChanged: throw error
                case .loginRequired: rejectedRefreshTokens[key] = refreshDigest
                default: break
                }
            }
            let current = try store.auth(for: account)
            if current.tokens != latest.tokens { return current }
            throw error
        }
    }
}
