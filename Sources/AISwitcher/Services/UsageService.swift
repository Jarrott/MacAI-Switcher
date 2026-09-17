import Foundation

/// Fetches 5h / 7d usage windows from the provider back-ends.
///
/// Endpoints and headers are taken from reverse-engineering the Codex CLI
/// (`chatgpt.com/backend-api/wham/usage`) and Claude Code
/// (`api.anthropic.com/api/oauth/usage`).
enum UsageService {

    enum FetchError: Error, LocalizedError {
        case noCredentials
        case unsupportedProvider
        case noResetCredit
        case http(Int)
        case decode
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "No credentials"
            case .unsupportedProvider: return "Reset credits are only supported for Codex"
            case .noResetCredit: return "No reset credit is available"
            case .http(let c): return "HTTP \(c)"
            case .decode: return "Bad response"
            case .network(let m): return m
            }
        }
    }

    /// Provider outcomes returned after an idempotent reset-credit request.
    enum ResetOutcome: Equatable {
        case reset
        case alreadyRedeemed
        case nothingToReset
        case noCredit
        case wrongProvider
    }

    // Browser UA is required for the Codex /wham/usage endpoint (else Cloudflare 403).
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    static let sessionWindowSeconds = 18_000  // 5h
    static let weeklyWindowSeconds = 604_800  // 7d

    private static let codexUsageURL = URL(
        string: "https://chatgpt.com/backend-api/wham/usage"
    )!
    private static let codexResetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    )!
    private static let codexConsumeResetURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"
    )!

    // MARK: Public entry point

    /// Fetch a complete usage snapshot for one account.
    ///
    /// - Parameter account: Managed account whose saved credential is used.
    /// - Returns: Fresh provider windows and best-effort reset-credit metadata.
    /// - Throws: `FetchError` for credentials, transport, HTTP, or decoding failures.
    /// - Side effects: May refresh and persist an expired OAuth token.
    static func fetch(for account: Account) async throws -> Usage {
        switch account.provider {
        case .codex: return try await fetchCodex(account)
        case .claude: return try await ClaudeUsageCoordinator.shared.fetch(for: account)
        }
    }

    /// Consume one manual Codex reset credit through an idempotent provider mutation.
    ///
    /// - Parameters:
    ///   - account: Codex account whose saved OAuth credential authorizes the request.
    ///   - creditID: Optional provider credit identifier, preferring the earliest expiry.
    ///   - idempotencyKey: Stable UUID for this logical attempt; reused only for the
    ///     single 401 token-refresh retry so the provider cannot consume twice.
    /// - Returns: The provider's explicit reset outcome.
    /// - Throws: `FetchError` for unsupported accounts, credentials, transport, HTTP,
    ///   or an unrecognized response. The method never treats an unknown body as success.
    /// - Side effects: May consume one irreversible reset credit and refresh an expired token.
    static func consumeResetCredit(
        for account: Account,
        creditID: String?,
        idempotencyKey: UUID = UUID()
    ) async throws -> ResetOutcome {
        guard account.provider == .codex else { throw FetchError.unsupportedProvider }
        guard (account.usage.resetsAvailable ?? 0) > 0 else { throw FetchError.noResetCredit }

        let auth: CodexAuth?
        if let snapshot = account.credentialSnapshot {
            auth = CodexCredentialStore.shared.loadSnapshot(snapshot)
        } else {
            auth = CodexCredentialStore.shared.currentAuth()
        }
        guard let auth,
            var accessToken = auth.tokens?.accessToken,
            let accountID = auth.accountID
        else { throw FetchError.noCredentials }

        if let expiry = auth.accessTokenExpiry, expiry < Date().addingTimeInterval(60),
            let fresh = await TokenRefresher.refreshCodex(
                auth: auth,
                snapshot: account.credentialSnapshot
            )
        {
            accessToken = fresh
        }

        let body = try JSONSerialization.data(
            withJSONObject: resetRequestPayload(
                creditID: creditID,
                idempotencyKey: idempotencyKey
            )
        )

        func request(_ token: String) -> URLRequest {
            var request = URLRequest(url: codexConsumeResetURL)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("codex-1", forHTTPHeaderField: "openai-beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
            request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
            request.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
            return request
        }

        var (data, response) = try await send(request(accessToken))
        var http = response as? HTTPURLResponse
        if http?.statusCode == 401,
            let fresh = await TokenRefresher.refreshCodex(
                auth: auth,
                snapshot: account.credentialSnapshot
            )
        {
            accessToken = fresh
            (data, response) = try await send(request(accessToken))
            http = response as? HTTPURLResponse
        }

        guard let http else { throw FetchError.decode }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(http.statusCode)
        }
        guard let outcome = parseResetOutcome(try decodeJSON(data)) else {
            throw FetchError.decode
        }
        return outcome
    }

    // MARK: Codex

    private static func fetchCodex(_ account: Account) async throws -> Usage {
        // Load the credentials for this account (from its snapshot, or the live file).
        let auth: CodexAuth?
        if let snap = account.credentialSnapshot {
            auth = CodexCredentialStore.shared.loadSnapshot(snap)
        } else {
            auth = CodexCredentialStore.shared.currentAuth()
        }
        guard let auth,
            var accessToken = auth.tokens?.accessToken,
            let accountID = auth.accountID
        else { throw FetchError.noCredentials }

        // Proactively refresh if the access token is already expired.
        if let exp = auth.accessTokenExpiry, exp < Date().addingTimeInterval(60) {
            if let fresh = await TokenRefresher.refreshCodex(
                auth: auth,
                snapshot: account.credentialSnapshot)
            {
                accessToken = fresh
            }
        }

        func request(_ token: String) -> URLRequest {
            var req = URLRequest(url: codexUsageURL)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
            req.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
            return req
        }

        var (data, resp) = try await send(request(accessToken))
        var http = resp as? HTTPURLResponse

        // On 401 (expired/invalid), refresh once and retry. Never on 403 (that's
        // a Cloudflare challenge, not an auth problem).
        if http?.statusCode == 401,
            let fresh = await TokenRefresher.refreshCodex(
                auth: auth,
                snapshot: account.credentialSnapshot)
        {
            accessToken = fresh
            (data, resp) = try await send(request(fresh))
            http = resp as? HTTPURLResponse
        }

        guard let http else { throw FetchError.decode }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }

        let payload = try decodeJSON(data)
        var usage = parseCodex(payload)
        // Reset credits are intentionally best-effort. A failure here must not
        // hide otherwise valid 5h/7d usage or masquerade as zero credits.
        if let resetSummary = await fetchCodexResetCredits(
            accessToken: accessToken,
            accountID: accountID
        ) {
            usage.resetsAvailable = resetSummary.count
            usage.resetCredits = resetSummary.credits
        }
        return usage
    }

    /// Codex `/wham/usage` response → Usage, classifying windows by length.
    static func parseCodex(_ obj: [String: Any]) -> Usage {
        let rl = obj["rate_limit"] as? [String: Any] ?? [:]

        func window(_ dict: Any?) -> (window: UsageWindow, seconds: Int)? {
            guard let d = dict as? [String: Any] else { return nil }
            let pct = jsonNumber(d["used_percent"])
            let seconds =
                (d["limit_window_seconds"] as? Int)
                ?? (d["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            var reset: Date?
            if let r = jsonNumber(d["reset_at"]) {
                reset = Date(timeIntervalSince1970: r)
            }
            let uw = UsageWindow(usedFraction: pct.map { $0 / 100.0 }, resetsAt: reset)
            return (uw, seconds)
        }

        var five = UsageWindow.unknown
        var seven = UsageWindow.unknown
        for key in ["primary_window", "secondary_window"] {
            guard let (uw, seconds) = window(rl[key]) else { continue }
            // Classify by the window length, not its position (backend reorders these).
            if seconds == sessionWindowSeconds {
                five = uw
            } else if seconds == weeklyWindowSeconds {
                seven = uw
            } else if seconds > 0 && seconds < 86_400 {
                five = uw
            } else if seconds >= 86_400 {
                seven = uw
            }
        }

        return Usage(fiveHour: five, sevenDay: seven, resetsAvailable: nil, fetchedAt: Date())
    }

    /// Fetch the independent manual reset-credit counter used by Codex Desktop.
    /// An unavailable endpoint returns `nil`; callers must never convert it to 0.
    private static func fetchCodexResetCredits(
        accessToken: String,
        accountID: String
    ) async -> (count: Int, credits: [ResetCredit]?)? {
        var req = URLRequest(url: codexResetCreditsURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-1", forHTTPHeaderField: "openai-beta")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        guard let (data, response) = try? await session.data(for: req),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let payload = try? decodeJSON(data)
        else { return nil }
        guard let count = parseResetCredits(payload) else { return nil }
        return (count, parseResetCreditDetails(payload))
    }

    /// Parse the dedicated reset-credit payload.
    ///
    /// - Parameter obj: Decoded provider JSON.
    /// - Returns: A non-negative count, or `nil` for missing/non-numeric data.
    /// Negative provider values are defensively clamped to zero.
    static func parseResetCredits(_ obj: [String: Any]) -> Int? {
        guard let rawCount = jsonNumber(obj["available_count"]) else { return nil }
        if rawCount <= 0 { return 0 }
        if rawCount >= Double(Int.max) { return Int.max }
        return Int(rawCount.rounded(.towardZero))
    }

    /// Parse available manual reset credits for the compact details popover.
    ///
    /// - Parameters:
    ///   - obj: Decoded reset-credit response.
    ///   - now: Reference time used to exclude expired rows; injectable for tests.
    /// - Returns: Available rows sorted by nearest expiry, or `nil` when the
    ///   provider omitted its `credits` collection.
    static func parseResetCreditDetails(
        _ obj: [String: Any],
        now: Date = Date()
    ) -> [ResetCredit]? {
        guard let rows = obj["credits"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> ResetCredit? in
            guard let id = row["id"] as? String,
                !id.isEmpty,
                (row["status"] as? String)?.lowercased() == "available"
            else { return nil }

            let expiresAt = (row["expires_at"] as? String).flatMap(ISO8601DateFormatter.parse)
            if let expiresAt, expiresAt <= now { return nil }
            return ResetCredit(
                id: id,
                title: row["title"] as? String,
                expiresAt: expiresAt
            )
        }.sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case (.some(let lhsDate), .some(let rhsDate)): return lhsDate < rhsDate
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
    }

    /// Build the provider body without logging credentials or mutation identifiers.
    ///
    /// - Parameters:
    ///   - creditID: Optional concrete credit to consume.
    ///   - idempotencyKey: UUID protecting the request from duplicate consumption.
    /// - Returns: JSON-compatible string dictionary used by the POST request.
    static func resetRequestPayload(
        creditID: String?,
        idempotencyKey: UUID
    ) -> [String: String] {
        var payload = ["redeem_request_id": idempotencyKey.uuidString.lowercased()]
        if let creditID = creditID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !creditID.isEmpty
        {
            payload["credit_id"] = creditID
        }
        return payload
    }

    /// Parse documented app-server and private backend reset outcome spellings.
    ///
    /// - Parameter obj: Decoded provider response.
    /// - Returns: A recognized outcome, or `nil` so callers fail closed.
    static func parseResetOutcome(_ obj: [String: Any]) -> ResetOutcome? {
        let nested = obj["result"] as? [String: Any]
        let raw =
            (obj["code"] as? String)
            ?? (obj["outcome"] as? String)
            ?? (obj["status"] as? String)
            ?? (nested?["code"] as? String)
            ?? (nested?["outcome"] as? String)
            ?? (nested?["status"] as? String)
        guard let raw else { return nil }
        let normalized =
            raw
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "reset": return .reset
        case "alreadyredeemed": return .alreadyRedeemed
        case "nothingtoreset": return .nothingToReset
        case "nocredit": return .noCredit
        case "resetwrongprovider", "wrongprovider": return .wrongProvider
        default: return nil
        }
    }

    // MARK: Claude

    /// Fetch Claude usage with one token exchange at most and one bounded 401 retry.
    /// - Parameters: `account` owns the snapshot; store/transport overrides isolate regression tests.
    /// - Returns: Parsed usage. Existing UI data is retained by AccountsManager on any failure.
    /// - Throws: Sanitized Claude auth errors or usage HTTP/decoding errors.
    /// - Side effects: Reconciles live credentials and durably saves rotated fields before use.
    static func fetchClaude(
        _ account: Account,
        store: ClaudeCredentialStore = .shared,
        transport: ClaudeOAuthService.Transport = ClaudeOAuthService.send
    ) async throws -> Usage {
        var auth = try store.auth(for: account)
        var exchanged = false

        func renew(_ base: ClaudeAuth) async throws -> ClaudeAuth {
            do {
                let updated = try await ClaudeOAuthService.refresh(auth: base, transport: transport)
                try store.persistRefreshedAuth(
                    base: base, updated: updated, snapshot: account.credentialSnapshot)
                return updated
            } catch {
                // Claude Code may have won the refresh race. Re-read before asking for login.
                // Persistence failures must remain visible even if the snapshot was saved.
                if let authError = error as? ClaudeAuthError {
                    switch authError {
                    case .persistence, .credentialChanged: throw error
                    default: break
                    }
                }
                if let latest = try? store.auth(for: account),
                    ClaudeCredentialStore.fingerprint(latest)
                        != ClaudeCredentialStore.fingerprint(base)
                {
                    return latest
                }
                throw error
            }
        }

        if let expiry = auth.accessTokenExpiry, expiry < Date().addingTimeInterval(60) {
            auth = try await renew(auth)
            exchanged = true
        }

        func request(_ auth: ClaudeAuth) throws -> URLRequest {
            guard let token = auth.accessToken, !token.isEmpty else {
                throw ClaudeAuthError.missingCredentials
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1.206 (external, cli)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return req
        }

        var (data, response) = try await transport(request(auth))
        if response.statusCode == 401 {
            let latest = try store.auth(for: account)
            if ClaudeCredentialStore.fingerprint(latest) != ClaudeCredentialStore.fingerprint(auth)
            {
                auth = latest
            } else if !exchanged {
                auth = try await renew(latest)
            } else {
                throw ClaudeAuthError.loginRequired
            }
            (data, response) = try await transport(request(auth))
        }
        if response.statusCode == 401 { throw ClaudeAuthError.loginRequired }
        guard (200..<300).contains(response.statusCode) else {
            throw FetchError.http(response.statusCode)
        }
        return parseClaude(try decodeJSON(data))
    }

    /// Claude `/api/oauth/usage` response → Usage. Utilization is 0..100.
    static func parseClaude(_ obj: [String: Any]) -> Usage {
        func window(_ key: String) -> UsageWindow {
            guard let d = obj[key] as? [String: Any] else { return .unknown }
            let util = jsonNumber(d["utilization"])
            var reset: Date?
            if let s = d["resets_at"] as? String {
                reset = ISO8601DateFormatter.parse(s)
            }
            return UsageWindow(usedFraction: util.map { $0 / 100.0 }, resetsAt: reset)
        }
        return Usage(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            resetsAvailable: nil,
            fetchedAt: Date()
        )
    }

    // MARK: Helpers

    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
    }

    private static func decodeJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FetchError.decode }
        return obj
    }

    /// Read a finite JSON number without treating JSON booleans as 0/1 values.
    private static func jsonNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

extension ISO8601DateFormatter {
    /// Parse an ISO-8601 timestamp with or without fractional seconds.
    static func parse(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
