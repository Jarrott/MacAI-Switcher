import CryptoKit
import Foundation

/// Safe Gemini authentication failures. Provider bodies and credentials never reach the UI.
enum GeminiAuthError: Error, LocalizedError {
    case missingCredentials
    case loginRequired
    case oauthClientUnavailable
    case network
    case refreshHTTP(Int)
    case invalidResponse
    case persistence
    case credentialChanged

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Gemini credentials are unavailable. Import the current login."
        case .loginRequired:
            return "Gemini login needs authorization. Sign in again without removing the account."
        case .oauthClientUnavailable:
            return
                "Gemini token expired and the CLI OAuth client could not be located. Sign in again or install the gemini CLI."
        case .network:
            return "The Gemini authentication service could not be reached."
        case .refreshHTTP(let status):
            return "Gemini token refresh failed (HTTP \(status))."
        case .invalidResponse:
            return "Gemini returned an invalid token response."
        case .persistence:
            return "Gemini credentials could not be saved securely."
        case .credentialChanged:
            return "Gemini credentials changed during refresh. Refresh again."
        }
    }

    /// Resolve safe failure categories in the selected UI language; API diagnostics stay English.
    @MainActor var displayMessage: String {
        switch self {
        case .missingCredentials: return appLocalized("gemini.auth.missing")
        case .loginRequired: return appLocalized("gemini.auth.login_required")
        case .oauthClientUnavailable: return appLocalized("gemini.auth.client_unavailable")
        case .network: return appLocalized("gemini.auth.network")
        case .refreshHTTP(let status):
            return String(format: appLocalized("gemini.auth.refresh_http"), status)
        case .invalidResponse: return appLocalized("gemini.auth.invalid_response")
        case .persistence: return appLocalized("gemini.auth.persistence")
        case .credentialChanged: return appLocalized("gemini.auth.changed")
        }
    }
}

/// Public desktop OAuth client credentials extracted dynamically from local CLI or env.
struct GeminiOAuthClientCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String
}

/// Exchanges Gemini CLI OAuth tokens without embedding any client secret in source code.
enum GeminiOAuthService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias ClientCredentialsResolver = @Sendable (GeminiAuth) -> GeminiOAuthClientCredentials?

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Double?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    /// Send a request with bounded timeout and sanitized transport errors; never logs credentials.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GeminiAuthError.invalidResponse
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GeminiAuthError {
            throw error
        } catch {
            throw GeminiAuthError.network
        }
    }

    /// Resolve Gemini CLI's OAuth client ID and secret from credential JSON, environment,
    /// or the installed `gemini` CLI package without storing secrets in this repository.
    static func discoverClientCredentials(
        for auth: GeminiAuth,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil
    ) -> GeminiOAuthClientCredentials? {
        if let id = trimmedNonEmpty(auth.clientID),
            let secret = trimmedNonEmpty(auth.clientSecret)
        {
            return GeminiOAuthClientCredentials(clientID: id, clientSecret: secret)
        }
        if let id = trimmedNonEmpty(environment["GEMINI_OAUTH_CLIENT_ID"]),
            let secret = trimmedNonEmpty(environment["GEMINI_OAUTH_CLIENT_SECRET"])
        {
            return GeminiOAuthClientCredentials(clientID: id, clientSecret: secret)
        }
        if let explicitPath = trimmedNonEmpty(environment["GEMINI_OAUTH2_JS_PATH"]),
            let extracted = extractClientCredentials(
                fromFileURL: URL(fileURLWithPath: explicitPath))
        {
            return extracted
        }
        let binaryURL = executableURL ?? CLIBrowserLoginService.executableURL(named: "gemini")
        guard let binaryURL else { return nil }
        for candidate in oauthScriptCandidates(fromExecutable: binaryURL) {
            if let extracted = extractClientCredentials(fromFileURL: candidate) {
                return extracted
            }
        }
        return nil
    }

    /// Parse `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` assignments from a local CLI JS file.
    static func extractClientCredentials(fromFileURL url: URL) -> GeminiOAuthClientCredentials? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return extractClientCredentials(fromScript: text)
    }

    /// Parse OAuth client ID and secret declarations from Gemini CLI JavaScript source.
    static func extractClientCredentials(fromScript text: String) -> GeminiOAuthClientCredentials? {
        guard
            let clientID = firstCapture(
                pattern: #"OAUTH_CLIENT_ID\s*[:=]\s*['"]([^'"]+)['"]"#, in: text),
            let clientSecret = firstCapture(
                pattern: #"OAUTH_CLIENT_SECRET\s*[:=]\s*['"]([^'"]+)['"]"#, in: text),
            !clientID.isEmpty, !clientSecret.isEmpty
        else { return nil }
        return GeminiOAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    /// Exchange one refresh token for a fresh Google OAuth access token.
    static func refresh(
        auth: GeminiAuth,
        clientCredentials: GeminiOAuthClientCredentials? = nil,
        credentialsResolver: ClientCredentialsResolver = { discoverClientCredentials(for: $0) },
        transport: Transport = send
    ) async throws -> GeminiAuth {
        guard let refreshToken = trimmedNonEmpty(auth.refreshToken) else {
            throw GeminiAuthError.loginRequired
        }
        guard let client = clientCredentials ?? credentialsResolver(auth) else {
            throw GeminiAuthError.oauthClientUnavailable
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncodedBody([
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String? }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.lowercased()
            if response.statusCode == 401 || code == "invalid_grant" || code == "invalid_client" {
                throw GeminiAuthError.loginRequired
            }
            throw GeminiAuthError.refreshHTTP(response.statusCode)
        }

        guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data),
            let newAccess = trimmedNonEmpty(result.accessToken),
            result.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else {
            throw GeminiAuthError.invalidResponse
        }
        if let expiresIn = result.expiresIn, !expiresIn.isFinite || expiresIn <= 0 {
            throw GeminiAuthError.invalidResponse
        }

        var updated = auth
        updated.accessToken = newAccess
        updated.refreshToken = result.refreshToken ?? refreshToken
        if let idToken = trimmedNonEmpty(result.idToken) { updated.idToken = idToken }
        if let scope = trimmedNonEmpty(result.scope) { updated.scope = scope }
        if let tokenType = trimmedNonEmpty(result.tokenType) { updated.tokenType = tokenType }
        if let expiresIn = result.expiresIn {
            updated.expiryDate = (Date().timeIntervalSince1970 + expiresIn) * 1_000
        } else {
            updated.expiryDate = nil
        }
        updated.accountEmail = updated.email ?? auth.email
        updated.accountSub = updated.subject ?? auth.subject
        return updated
    }

    /// Encode application/x-www-form-urlencoded fields using strict RFC 3986 unreserved characters.
    static func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let encoded = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func oauthScriptCandidates(fromExecutable executableURL: URL) -> [URL] {
        let resolved = executableURL.resolvingSymlinksInPath()
        var roots: [URL] = []
        var cursor = resolved.deletingLastPathComponent()
        for _ in 0..<5 {
            roots.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
        let relativePaths = [
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "bundle/gemini.js",
            "dist/src/code_assist/oauth2.js",
            "src/code_assist/oauth2.js",
        ]
        var seen = Set<String>()
        var candidates: [URL] = []
        for root in roots {
            for relative in relativePaths {
                let candidate = root.appendingPathComponent(relative).standardizedFileURL
                if seen.insert(candidate.path).inserted {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Shares Gemini token exchanges across usage requests with bounded 401 retry.
actor GeminiAuthCoordinator {
    static let shared = GeminiAuthCoordinator()

    private let store: GeminiCredentialStore
    private let transport: GeminiOAuthService.Transport
    private let credentialsResolver: GeminiOAuthService.ClientCredentialsResolver
    private var renewals: [String: Task<GeminiAuth, Error>] = [:]
    private var rejectedRefreshTokens: [String: String] = [:]
    private struct Rotation {
        let base: GeminiAuth
        let updated: GeminiAuth
    }
    private var pendingRotations: [String: Rotation] = [:]

    init(
        store: GeminiCredentialStore = .shared,
        transport: @escaping GeminiOAuthService.Transport = GeminiOAuthService.send,
        credentialsResolver: @escaping GeminiOAuthService.ClientCredentialsResolver = {
            GeminiOAuthService.discoverClientCredentials(for: $0)
        }
    ) {
        self.store = store
        self.transport = transport
        self.credentialsResolver = credentialsResolver
    }

    /// Authorize one Gemini API request, adopting CLI rotations first and retrying at most one 401.
    func send(
        _ request: URLRequest,
        for account: Account
    ) async throws -> (Data, HTTPURLResponse, GeminiAuth) {
        var auth = try currentAuth(for: account)
        var exchanged = false
        if let expiry = auth.accessTokenExpiry, expiry < Date().addingTimeInterval(60) {
            auth = try await renew(auth, for: account)
            exchanged = true
        }

        func authorized(_ auth: GeminiAuth) -> URLRequest {
            var result = request
            result.setValue(
                "Bearer \(auth.accessToken ?? "")",
                forHTTPHeaderField: "Authorization"
            )
            return result
        }

        var (data, response) = try await transport(authorized(auth))
        if response.statusCode == 401 {
            let latest = try currentAuth(for: account)
            if GeminiCredentialStore.fingerprint(latest) != GeminiCredentialStore.fingerprint(auth)
            {
                auth = latest
            } else if !exchanged {
                auth = try await renew(latest, for: account)
            } else {
                throw GeminiAuthError.loginRequired
            }
            (data, response) = try await transport(authorized(auth))
        }
        guard response.statusCode != 401 else { throw GeminiAuthError.loginRequired }
        return (data, response, auth)
    }

    private func currentAuth(for account: Account) throws -> GeminiAuth {
        let auth = try store.auth(for: account)
        let key = account.accountID ?? account.id.uuidString
        guard let rotation = pendingRotations[key] else { return auth }
        if GeminiCredentialStore.fingerprint(auth)
            == GeminiCredentialStore.fingerprint(rotation.base)
        {
            try store.persistRefreshedAuth(base: auth, updated: rotation.updated, for: account)
            pendingRotations.removeValue(forKey: key)
            return rotation.updated
        }
        pendingRotations.removeValue(forKey: key)
        return auth
    }

    private func renew(_ base: GeminiAuth, for account: Account) async throws -> GeminiAuth {
        let latest = try currentAuth(for: account)
        if GeminiCredentialStore.fingerprint(latest) != GeminiCredentialStore.fingerprint(base) {
            return latest
        }
        let key = account.accountID ?? account.id.uuidString
        if let pending = renewals[key] { return try await pending.value }
        let refreshDigest = SHA256.hash(data: Data((latest.refreshToken ?? "").utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard rejectedRefreshTokens[key] != refreshDigest else {
            throw GeminiAuthError.loginRequired
        }

        let store = self.store
        let transport = self.transport
        let credentialsResolver = self.credentialsResolver
        let task = Task {
            let updated = try await GeminiOAuthService.refresh(
                auth: latest,
                credentialsResolver: credentialsResolver,
                transport: transport
            )
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
            if let failure = error as? GeminiAuthError {
                switch failure {
                case .persistence, .credentialChanged: throw error
                case .loginRequired: rejectedRefreshTokens[key] = refreshDigest
                default: break
                }
            }
            let current = try store.auth(for: account)
            if GeminiCredentialStore.fingerprint(current)
                != GeminiCredentialStore.fingerprint(latest)
            {
                return current
            }
            throw error
        }
    }
}
