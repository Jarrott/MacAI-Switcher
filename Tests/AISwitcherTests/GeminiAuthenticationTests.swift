import Foundation
import XCTest

@testable import AISwitcher

/// Synthetic credentials and isolated directories exercise Gemini OAuth, switching,
/// and quota fetching without touching live accounts or external networks.
@MainActor
final class GeminiAuthenticationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: GeminiCredentialStore
        let account: Account

        init(
            _ auth: GeminiAuth,
            live: GeminiAuth? = nil,
            recordedEmail: String? = nil
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            store = GeminiCredentialStore(
                authURL: directory.appendingPathComponent("oauth_creds.json"),
                accountsFileURL: directory.appendingPathComponent("google_accounts.json"),
                snapshotsDir: directory.appendingPathComponent("snapshots", isDirectory: true)
            )
            let id = try XCTUnwrap(auth.stableAccountID)
            let snapshot = try XCTUnwrap(
                store.snapshot(data: JSONEncoder().encode(auth), accountID: id))
            account = Account(
                provider: .gemini,
                label: GeminiCredentialStore.preferredLabel(email: auth.email, name: auth.name),
                email: auth.email,
                plan: .unknown,
                accountID: id,
                credentialSnapshot: snapshot
            )
            if let live {
                try SecureFileWriter.write(JSONEncoder().encode(live), to: store.authURL)
            }
            if let recordedEmail {
                let record = Data(#"{"active":"\#(recordedEmail)","old":[]}"#.utf8)
                try SecureFileWriter.write(record, to: store.accountsFileURL)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private actor Server {
        struct Reply: Sendable {
            let status: Int
            let body: String
        }
        var replies: [Reply]
        private(set) var requests: [URLRequest] = []

        init(_ replies: [Reply]) { self.replies = replies }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw GeminiAuthError.invalidResponse }
            let reply = replies.removeFirst()
            return (
                Data(reply.body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    private let syntheticClient = GeminiOAuthClientCredentials(
        clientID: "synthetic-client-id.apps.googleusercontent.com",
        clientSecret: "synthetic-client-secret"
    )
    private let loadBody =
        #"{"cloudaicompanionProject":"synthetic-proj","paidTier":{"id":"g1-ultra-tier"}}"#
    private let quotaBody =
        #"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.62,"resetTime":"2026-08-09T10:00:00Z"},{"modelId":"gemini-2.5-flash","remainingFraction":0.88,"resetTime":"2026-08-09T11:00:00Z"}]}"#
    private let tokenBody =
        #"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#

    private func makeIDToken(email: String, sub: String, name: String? = nil) -> String {
        var claims: [String: Any] = ["email": email, "sub": sub]
        if let name { claims["name"] = name }
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).sig"
    }

    private func auth(
        access: String = "old-access",
        refresh: String = "1//synthetic-refresh+token/value=",
        email: String = "alice@example.com",
        sub: String = "sub-alice",
        expired: Bool = false
    ) -> GeminiAuth {
        let expiryMs =
            Date().addingTimeInterval(expired ? -300 : 3_600).timeIntervalSince1970 * 1_000
        return GeminiAuth(
            accessToken: access,
            refreshToken: refresh,
            idToken: makeIDToken(email: email, sub: sub, name: "Alice Dev"),
            scope: "openid email profile",
            tokenType: "Bearer",
            expiryDate: expiryMs
        )
    }

    private func fetch(_ fixture: Fixture, server: Server) async throws -> Usage {
        let client = syntheticClient
        let coordinator = GeminiAuthCoordinator(
            store: fixture.store,
            transport: server.send,
            credentialsResolver: { _ in client }
        )
        return try await UsageService.fetchGemini(fixture.account, coordinator: coordinator)
    }

    func testFetchGeminiParsesCodeAssistAndQuotaAndUpdatesPlan() async throws {
        let fixture = try Fixture(auth())
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: loadBody),
            .init(status: 200, body: quotaBody),
        ])

        let usage = try await fetch(fixture, server: server)

        XCTAssertEqual(try XCTUnwrap(usage.fiveHour.remainingFraction), 0.62, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay.remainingFraction), 0.88, accuracy: 0.000_1)
        XCTAssertEqual(usage.discoveredPlan, .ultra)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, UsageService.geminiLoadCodeAssistURL)
        XCTAssertEqual(requests[1].url, UsageService.geminiRetrieveQuotaURL)
        let quotaPayload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody))
                as? [String: String]
        )
        XCTAssertEqual(quotaPayload["project"], "synthetic-proj")
    }

    func testExpiredTokenRefreshesWithFormEncodingAndPersistsToSnapshotAndLive() async throws {
        let base = auth(expired: true)
        let fixture = try Fixture(base, live: base)
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: tokenBody),
            .init(status: 200, body: loadBody),
            .init(status: 200, body: quotaBody),
        ])

        let usage = try await fetch(fixture, server: server)
        XCTAssertEqual(try XCTUnwrap(usage.fiveHour.remainingFraction), 0.62, accuracy: 0.000_1)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url, GeminiOAuthService.tokenURL)
        let formBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(formBody.contains("grant_type=refresh_token"))
        XCTAssertTrue(
            formBody.contains("refresh_token=1%2F%2Fsynthetic-refresh%2Btoken%2Fvalue%3D"))
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")

        let saved = try fixture.store.auth(for: fixture.account)
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, base.refreshToken)
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "new-access")
        let liveText = String(decoding: try Data(contentsOf: fixture.store.authURL), as: UTF8.self)
        XCTAssertFalse(liveText.contains("aiSwitcher"))
        let permissions =
            try FileManager.default.attributesOfItem(atPath: fixture.store.authURL.path)[
                .posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func test401RefreshesOnceAndRetriesWithPersistedToken() async throws {
        let fixture = try Fixture(auth(expired: false))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 401, body: "{}"),
            .init(status: 200, body: tokenBody),
            .init(status: 200, body: loadBody),
            .init(status: 200, body: quotaBody),
        ])

        _ = try await fetch(fixture, server: server)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url, GeminiOAuthService.tokenURL)
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func test403And429DoNotRefreshTokens() async throws {
        for status in [403, 429] {
            let fixture = try Fixture(auth(expired: false))
            defer { fixture.cleanUp() }
            let server = Server([
                .init(status: 200, body: loadBody),
                .init(status: status, body: "{}"),
            ])
            do {
                _ = try await fetch(fixture, server: server)
                XCTFail("Expected HTTP failure")
            } catch UsageService.FetchError.http(let value) {
                XCTAssertEqual(value, status)
            }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testMatchingLiveCLIRotationAvoidsOAuthRefresh() async throws {
        let fixture = try Fixture(
            auth(access: "old-access", expired: true),
            live: auth(access: "cli-fresh-access", expired: false)
        )
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: loadBody),
            .init(status: 200, body: quotaBody),
        ])

        _ = try await fetch(fixture, server: server)

        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer cli-fresh-access")
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "cli-fresh-access")
    }

    func testInactiveAccountNeverUsesOrOverwritesOtherLiveLogin() async throws {
        let other = auth(
            access: "other-access",
            refresh: "other-refresh",
            email: "bob@example.com",
            sub: "sub-bob",
            expired: false
        )
        let fixture = try Fixture(auth(expired: true), live: other)
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: tokenBody),
            .init(status: 200, body: loadBody),
            .init(status: 200, body: quotaBody),
        ])

        _ = try await fetch(fixture, server: server)
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "other-access")
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "new-access")
    }

    func testRejectedRefreshIsLatchedUntilCredentialChanges() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 400, body: #"{"error":"invalid_grant"}"#),
            .init(status: 200, body: "{}"),
        ])
        let client = syntheticClient
        let coordinator = GeminiAuthCoordinator(
            store: fixture.store,
            transport: server.send,
            credentialsResolver: { _ in client }
        )
        let req = URLRequest(url: UsageService.geminiRetrieveQuotaURL)

        for _ in 0..<2 {
            do {
                _ = try await coordinator.send(req, for: fixture.account)
                XCTFail("Expected loginRequired")
            } catch GeminiAuthError.loginRequired {}
        }
        var requests = await server.requests
        XCTAssertEqual(requests.count, 1)

        try SecureFileWriter.write(
            JSONEncoder().encode(auth(access: "cli-access", refresh: "new-r", expired: false)),
            to: fixture.store.authURL
        )
        _ = try await coordinator.send(req, for: fixture.account)
        requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
    }

    func testConcurrentOperationsShareOneExchange() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server(
            [.init(status: 200, body: tokenBody)]
                + Array(repeating: .init(status: 200, body: "{}"), count: 10))
        let client = syntheticClient
        let coordinator = GeminiAuthCoordinator(
            store: fixture.store,
            transport: { request in
                let response = try await server.send(request)
                if request.url == GeminiOAuthService.tokenURL {
                    try await Task.sleep(for: .milliseconds(50))
                }
                return response
            },
            credentialsResolver: { _ in client }
        )
        let req = URLRequest(url: UsageService.geminiRetrieveQuotaURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try await coordinator.send(req, for: fixture.account) }
            }
            try await group.waitForAll()
        }
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0.url == GeminiOAuthService.tokenURL }.count, 1)
        XCTAssertEqual(requests.count, 11)
    }

    func testClientCredentialsExtractionFromSyntheticScriptAndMissingClientError() async throws {
        let js = """
            const OAUTH_CLIENT_ID = '12345-synthetic.apps.googleusercontent.com';
            const OAUTH_CLIENT_SECRET = 'SYNTHETIC-SECRET-VALUE';
            """
        let extracted = try XCTUnwrap(GeminiOAuthService.extractClientCredentials(fromScript: js))
        XCTAssertEqual(extracted.clientID, "12345-synthetic.apps.googleusercontent.com")
        XCTAssertEqual(extracted.clientSecret, "SYNTHETIC-SECRET-VALUE")

        let server = Server([])
        do {
            _ = try await GeminiOAuthService.refresh(
                auth: auth(expired: true),
                credentialsResolver: { _ in nil },
                transport: server.send
            )
            XCTFail("Expected oauthClientUnavailable")
        } catch GeminiAuthError.oauthClientUnavailable {}
    }

    func testDiscoveryUsesGoogleAccountsFallbackAndSwitchingUpdatesLiveFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = GeminiCredentialStore(
            authURL: dir.appendingPathComponent("oauth_creds.json"),
            accountsFileURL: dir.appendingPathComponent("google_accounts.json"),
            snapshotsDir: dir.appendingPathComponent("snapshots", isDirectory: true)
        )
        // Credential without id_token relies on google_accounts.json for email identity.
        let credWithoutIDToken = GeminiAuth(accessToken: "alice-token", refreshToken: "alice-ref")
        try SecureFileWriter.write(JSONEncoder().encode(credWithoutIDToken), to: store.authURL)
        try SecureFileWriter.write(
            Data(#"{"active":"alice@example.com","old":[]}"#.utf8),
            to: store.accountsFileURL
        )

        let manager = AccountsManager(ephemeral: true, geminiStore: store) { _ in
            Usage(
                fiveHour: UsageWindow(usedFraction: 0.2, resetsAt: nil),
                sevenDay: UsageWindow(usedFraction: 0.1, resetsAt: nil),
                resetsAvailable: nil,
                fetchedAt: Date(),
                discoveredPlan: .pro
            )
        }
        let imported = await manager.importCurrentAccount(provider: .gemini)
        let alice = try XCTUnwrap(imported?.account)
        XCTAssertEqual(alice.label, "alice")
        XCTAssertEqual(alice.email, "alice@example.com")
        XCTAssertTrue(manager.isActive(alice))

        await manager.refreshAll()
        XCTAssertEqual(manager.accounts.first?.plan, .pro)

        // Import second Gemini account and switch to it.
        let bob = try await manager.importCredentialData(
            provider: .gemini,
            data: JSONEncoder().encode(
                auth(
                    access: "bob-token",
                    refresh: "bob-ref",
                    email: "bob@example.com",
                    sub: "sub-bob"
                )
            )
        ).account
        await manager.activate(bob)

        XCTAssertTrue(manager.isActive(bob))
        XCTAssertEqual(store.currentAuth()?.accessToken, "bob-token")
        XCTAssertEqual(store.liveRecordedEmail(), "bob@example.com")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.authURL.appendingPathExtension("switcher-bak").path
            )
        )
    }

    func testPersistencePreservesUnknownFieldsAndPathTraversalIsRejected() throws {
        let base = auth()
        let fixture = try Fixture(base, live: base)
        defer { fixture.cleanUp() }

        let custom = Data(
            #"{"access_token":"old-access","refresh_token":"1//synthetic-refresh+token/value=","id_token":"\#(base.idToken!)","future_field":"keep-me"}"#
                .utf8
        )
        _ = fixture.store.snapshot(data: custom, accountID: try XCTUnwrap(base.stableAccountID))
        try fixture.store.persistRefreshedAuth(
            base: base,
            updated: auth(access: "rotated-access"),
            for: fixture.account
        )
        let liveObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.authURL))
                as? [String: Any]
        )
        XCTAssertEqual(liveObj["future_field"] as? String, "keep-me")
        XCTAssertNil(liveObj["aiSwitcherPreviousCredentialFingerprint"])

        var unsafe = fixture.account
        unsafe.credentialSnapshot = "../oauth_creds.json"
        XCTAssertThrowsError(try fixture.store.auth(for: unsafe))
    }
}
