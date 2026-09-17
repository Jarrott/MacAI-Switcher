import Foundation

/// Refreshes expired Codex OAuth access tokens and writes them back to the
/// credential snapshot / live file so subsequent API calls succeed.
enum TokenRefresher {

    // Codex OAuth client id (from the access_token's `client_id` claim).
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: Codex

    /// Refresh a Codex access token. Returns the new access token, or nil on failure.
    /// Persists the rotated tokens back into the account's snapshot + live auth.json.
    @discardableResult
    static func refreshCodex(auth: CodexAuth, snapshot: String?) async -> String? {
        guard let refresh = auth.tokens?.refreshToken else { return nil }

        var req = URLRequest(url: codexTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": codexClientID,
            "scope": "openid profile email",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let obj = await postForJSON(req) else { return nil }
        guard let newAccess = obj["access_token"] as? String else { return nil }
        let newRefresh = obj["refresh_token"] as? String ?? refresh
        let newID = obj["id_token"] as? String ?? auth.tokens?.idToken

        persistCodex(
            base: auth, access: newAccess, refresh: newRefresh,
            idToken: newID, snapshot: snapshot)
        return newAccess
    }

    private static func persistCodex(
        base: CodexAuth, access: String,
        refresh: String, idToken: String?, snapshot: String?
    ) {
        var updated = base
        var tokens = updated.tokens ?? CodexAuth.Tokens()
        tokens.accessToken = access
        tokens.refreshToken = refresh
        tokens.idToken = idToken
        updated.tokens = tokens
        updated.lastRefresh = ISO8601DateFormatter().string(from: Date())

        guard let data = try? JSONEncoder().encode(updated) else { return }
        // Write back to the snapshot (if this account owns one)…
        if let snapshot {
            let url = CodexCredentialStore.shared.snapshotsDir.appendingPathComponent(snapshot)
            try? SecureFileWriter.write(data, to: url)
        }
        // …and to the live file if this account is the active one.
        if let live = CodexCredentialStore.shared.currentAuth(),
            live.accountID == updated.accountID
        {
            let authURL = CodexCredentialStore.shared.authURL
            // Back up the working file before overwriting, so a bad write is recoverable.
            if let cur = try? Data(contentsOf: authURL) {
                try? SecureFileWriter.write(
                    cur,
                    to: authURL.appendingPathExtension("switcher-bak")
                )
            }
            try? SecureFileWriter.write(data, to: authURL)
        }
    }

    // MARK: HTTP

    private static func postForJSON(_ req: URLRequest) async -> [String: Any]? {
        guard let (data, resp) = try? await session.data(for: req),
            let http = resp as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
