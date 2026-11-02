import Foundation

/// Safe Codex authentication failures. Provider bodies and credentials never reach the UI.
enum CodexAuthError: Error, LocalizedError {
    case missingCredentials
    case loginRequired
    case network
    case refreshHTTP(Int)
    case invalidResponse
    case persistence
    case credentialChanged

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Codex credentials are unavailable. Import the current login."
        case .loginRequired:
            return "Codex login needs authorization. Sign in again without removing the account."
        case .network: return "The Codex authentication service could not be reached."
        case .refreshHTTP(let status): return "Codex token refresh failed (HTTP \(status))."
        case .invalidResponse: return "Codex returned an invalid token response."
        case .persistence: return "Codex credentials could not be saved securely."
        case .credentialChanged: return "Codex credentials changed during refresh. Refresh again."
        }
    }

    /// Resolve safe failure categories in the selected UI language; API diagnostics stay English.
    @MainActor var displayMessage: String {
        switch self {
        case .missingCredentials: return appLocalized("codex.auth.missing")
        case .loginRequired: return appLocalized("codex.auth.login_required")
        case .network: return appLocalized("codex.auth.network")
        case .refreshHTTP(let status):
            return String(format: appLocalized("codex.auth.refresh_http"), status)
        case .invalidResponse: return appLocalized("codex.auth.invalid_response")
        case .persistence: return appLocalized("codex.auth.persistence")
        case .credentialChanged: return appLocalized("codex.auth.changed")
        }
    }
}

/// Exchanges Codex OAuth tokens without hiding authentication or persistence failures.
enum TokenRefresher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private struct RefreshRequest: Encodable {
        let grantType = "refresh_token"
        let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        let scope = "openid profile email"
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case clientID = "client_id"
            case scope
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    /// Send a request with bounded timeout and sanitized transport errors; never logs credentials.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw CodexAuthError.invalidResponse
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexAuthError {
            throw error
        } catch {
            throw CodexAuthError.network
        }
    }

    /// Exchange one latest refresh token, returning the complete credential for durable storage.
    /// - Parameters: `auth` is the verified generation; `transport` permits isolated HTTP tests.
    /// - Throws: Sanitized login, HTTP, network or malformed-response errors.
    /// - Side effects: Rotates server-side tokens; the caller must persist before using them.
    static func refreshCodex(
        auth: CodexAuth, transport: Transport = send
    ) async throws -> CodexAuth {
        guard let refresh = auth.tokens?.refreshToken, !refresh.isEmpty else {
            throw CodexAuthError.loginRequired
        }
        var request = URLRequest(url: codexTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: refresh))
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            // OpenAI may use either a string OAuth error or a nested error.code.
            struct Failure: Decodable {
                struct Detail: Decodable { let code: String? }
                let code: String?
                enum CodingKeys: String, CodingKey { case error }
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    code =
                        (try? values.decode(String.self, forKey: .error))
                        ?? (try? values.decode(Detail.self, forKey: .error))?.code
                }
            }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.code
            let rejected = [
                "invalid_grant", "refresh_token_reused", "refresh_token_expired",
                "refresh_token_invalidated",
            ]
            if response.statusCode == 401 || code.map(rejected.contains) == true {
                throw CodexAuthError.loginRequired
            }
            throw CodexAuthError.refreshHTTP(response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data),
            !result.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            result.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
            result.idToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else { throw CodexAuthError.invalidResponse }
        var updated = auth
        updated.tokens?.accessToken = result.accessToken
        updated.tokens?.refreshToken = result.refreshToken ?? refresh
        updated.tokens?.idToken = result.idToken ?? auth.tokens?.idToken
        updated.lastRefresh = ISO8601DateFormatter().string(from: Date())
        guard updated.accountID == auth.accountID else { throw CodexAuthError.invalidResponse }
        return updated
    }
}
