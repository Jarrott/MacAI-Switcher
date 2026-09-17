import Foundation

/// Safe, localized failure categories; provider bodies and credentials never enter UI errors.
enum ClaudeAuthError: Error {
    case missingCredentials
    case loginRequired
    case network
    case refreshHTTP(Int)
    case invalidResponse
    case persistence
    case credentialChanged

    /// Resolve the failure in the selected application language on the UI actor.
    @MainActor var displayMessage: String {
        switch self {
        case .refreshHTTP(let status):
            return String(format: appLocalized("claude.auth.refresh_http"), status)
        case .missingCredentials: return appLocalized("claude.auth.missing")
        case .loginRequired: return appLocalized("claude.auth.login_required")
        case .network: return appLocalized("claude.auth.network")
        case .invalidResponse: return appLocalized("claude.auth.invalid_response")
        case .persistence: return appLocalized("claude.auth.persistence")
        case .credentialChanged: return appLocalized("claude.auth.changed")
        }
    }
}

/// Claude-only OAuth exchange. Injectable transport keeps tests off real accounts and networks.
enum ClaudeOAuthService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// Send one request without exposing transport diagnostics containing credential material.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ClaudeAuthError.invalidResponse
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeAuthError {
            throw error
        } catch {
            throw ClaudeAuthError.network
        }
    }

    private struct RefreshRequest: Encodable {
        let grantType = "refresh_token"
        let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case clientID = "client_id"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let expiresAt: Double?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case scope
        }
    }

    /// Exchange one refresh token and return the complete updated credential.
    /// - Parameters: `auth` is the latest verified credential; `transport` sends the HTTP request.
    /// - Returns: Rotated tokens, scopes and expiry; omitted expiry becomes unknown, never stale.
    /// - Throws: A sanitized authentication, HTTP, transport or response error.
    /// - Side effects: Rotates server-side tokens; the caller must durably save the result.
    static func refresh(
        auth: ClaudeAuth, transport: Transport = send
    ) async throws -> ClaudeAuth {
        guard let token = auth.oauth?.refreshToken, !token.isEmpty else {
            throw ClaudeAuthError.loginRequired
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: token))
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if response.statusCode == 401 || failure?.error == "invalid_grant" {
                throw ClaudeAuthError.loginRequired
            }
            throw ClaudeAuthError.refreshHTTP(response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data),
            !result.accessToken.isEmpty,
            result.refreshToken?.isEmpty != true
        else { throw ClaudeAuthError.invalidResponse }
        var updated = auth
        updated.oauth?.accessToken = result.accessToken
        updated.oauth?.refreshToken = result.refreshToken ?? token
        updated.oauth?.expiresAt = nil
        if let duration = result.expiresIn {
            guard duration.isFinite, duration > 0 else { throw ClaudeAuthError.invalidResponse }
            updated.oauth?.expiresAt = (Date().timeIntervalSince1970 + duration) * 1_000
        } else if let expiry = result.expiresAt {
            guard expiry.isFinite, expiry > 0 else { throw ClaudeAuthError.invalidResponse }
            updated.oauth?.expiresAt = expiry > 10_000_000_000 ? expiry : expiry * 1_000
        }
        if let scope = result.scope {
            updated.oauth?.scopes = scope.split(separator: " ").map(String.init)
        }
        return updated
    }
}

/// Coalesces concurrent usage requests for the same Claude snapshot, including token rotation.
actor ClaudeUsageCoordinator {
    static let shared = ClaudeUsageCoordinator()
    private var requests: [String: Task<Usage, Error>] = [:]
    private let operation: @Sendable (Account) async throws -> Usage

    /// Inject the complete operation for deterministic concurrency tests; production uses HTTP/storage.
    init(
        operation: @escaping @Sendable (Account) async throws -> Usage = {
            try await UsageService.fetchClaude($0)
        }
    ) {
        self.operation = operation
    }

    /// Fetch once per managed snapshot; overlapping callers share persistence and failures.
    /// Completed tasks are removed so a later refresh can retry transient failures.
    func fetch(for account: Account) async throws -> Usage {
        let key = account.credentialSnapshot ?? account.id.uuidString
        if let request = requests[key] { return try await request.value }
        let request = Task { try await operation(account) }
        requests[key] = request
        defer { requests.removeValue(forKey: key) }
        return try await request.value
    }
}
