import Foundation
import XCTest

@testable import AISwitcher

/// All credentials are synthetic; storage and HTTP transport are isolated from the real CLI.
@MainActor
final class ClaudeAuthenticationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let live: URL
        let store: ClaudeCredentialStore
        let account: Account

        init(auth: ClaudeAuth, liveAuth: ClaudeAuth? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            live = directory.appendingPathComponent("live.json")
            store = ClaudeCredentialStore(
                snapshotsDir: directory, fileURL: live,
                readKeychain: { nil }, saveKeychain: { _ in false })
            let filename = try XCTUnwrap(
                store.snapshot(
                    data: JSONEncoder().encode(auth), accountID: "synthetic"))
            account = Account(
                provider: .claude, label: "Test", plan: .max, credentialSnapshot: filename)
            if let liveAuth { try SecureFileWriter.write(JSONEncoder().encode(liveAuth), to: live) }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Scripted HTTP responses record only synthetic requests for behavioral assertions.
    private actor Server {
        struct Reply: Sendable {
            let status: Int
            let body: String
        }
        var replies: [Reply]
        var requests: [URLRequest] = []

        init(_ replies: [Reply]) { self.replies = replies }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw ClaudeAuthError.invalidResponse }
            let reply = replies.removeFirst()
            return (
                Data(reply.body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    private func auth(
        _ access: String = "old-access", refresh: String = "old-refresh", expired: Bool = true
    ) -> ClaudeAuth {
        ClaudeAuth(
            oauth: .init(
                accessToken: access, refreshToken: refresh,
                expiresAt: Date().addingTimeInterval(expired ? -300 : 7200).timeIntervalSince1970
                    * 1_000,
                scopes: ["user:profile"], subscriptionType: "max"))
    }

    private let tokenBody =
        #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800}"#
    private let usageBody = #"{"five_hour":{"utilization":25},"seven_day":{"utilization":60}}"#

    /// Expiry triggers the current endpoint, saves both rotated tokens and then queries usage.
    func testExpiredTokenRefreshesAndPersistsToSnapshotAndLive() async throws {
        let original = auth()
        let fixture = try Fixture(auth: original, liveAuth: original)
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: tokenBody), .init(status: 200, body: usageBody),
        ])
        let usage = try await UsageService.fetchClaude(
            fixture.account, store: fixture.store, transport: server.send)
        XCTAssertEqual(usage.fiveHour.usedFraction, 0.25)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.first?.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        let body =
            try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody))
            as? [String: String]
        XCTAssertEqual(body?["refresh_token"], "old-refresh")
        XCTAssertEqual(body?["grant_type"], "refresh_token")
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        let saved = try fixture.store.auth(for: fixture.account)
        XCTAssertEqual(saved.oauth?.refreshToken, "new-refresh")
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "new-access")
        XCTAssertGreaterThan(try XCTUnwrap(saved.accessTokenExpiry), Date())
        let permissions =
            try FileManager.default.attributesOfItem(atPath: fixture.live.path)[.posixPermissions]
            as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// A fresh access token rejected by usage causes exactly one exchange and one retry.
    func test401RefreshesOnceWithLatestCredential() async throws {
        let fixture = try Fixture(auth: auth(expired: false))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 401, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 200, body: usageBody),
        ])
        _ = try await UsageService.fetchClaude(
            fixture.account, store: fixture.store, transport: server.send)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    /// After proactive rotation a 401 must not exchange the now-obsolete refresh token again.
    func test401AfterProactiveRefreshDoesNotRotateAgain() async throws {
        let fixture = try Fixture(auth: auth())
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: tokenBody), .init(status: 401, body: "{}")])
        do {
            _ = try await UsageService.fetchClaude(
                fixture.account, store: fixture.store, transport: server.send)
            XCTFail("Expected authentication failure")
        } catch ClaudeAuthError.loginRequired {}
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            try fixture.store.auth(for: fixture.account).oauth?.refreshToken, "new-refresh")
    }

    /// A live CLI access-token update with matching refresh-token ownership supersedes the snapshot.
    func testNewerRelatedLiveCredentialAvoidsRefresh() async throws {
        let fixture = try Fixture(auth: auth(), liveAuth: auth("cli-access", expired: false))
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: usageBody)])
        _ = try await UsageService.fetchClaude(
            fixture.account, store: fixture.store, transport: server.send)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "cli-access")
    }

    /// A different live account is neither used for usage nor overwritten by an inactive refresh.
    func testDifferentLiveAccountIsPreserved() async throws {
        let fixture = try Fixture(
            auth: auth(), liveAuth: auth("other-access", refresh: "other-refresh", expired: false))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: tokenBody), .init(status: 200, body: usageBody),
        ])
        _ = try await UsageService.fetchClaude(
            fixture.account, store: fixture.store, transport: server.send)
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "other-access")
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "new-access")
    }

    /// Missing managed storage must fail closed instead of adopting whichever CLI login is live.
    func testMissingSnapshotDoesNotFallBackToLiveAccount() throws {
        let fixture = try Fixture(auth: auth(), liveAuth: auth("other", refresh: "other"))
        defer { fixture.cleanUp() }
        XCTAssertTrue(
            fixture.store.removeSnapshot(try XCTUnwrap(fixture.account.credentialSnapshot)))
        XCTAssertThrowsError(try fixture.store.auth(for: fixture.account)) {
            guard case ClaudeAuthError.missingCredentials = $0 else {
                return XCTFail("Wrong error")
            }
        }
    }

    /// Rate limits and forbidden usage responses never trigger token rotation.
    func test403And429DoNotRefreshTokens() async throws {
        for status in [403, 429] {
            let fixture = try Fixture(auth: auth(expired: false))
            defer { fixture.cleanUp() }
            let server = Server([.init(status: status, body: "{}")])
            do {
                _ = try await UsageService.fetchClaude(
                    fixture.account, store: fixture.store, transport: server.send)
                XCTFail("Expected HTTP failure")
            } catch UsageService.FetchError.http(let actual) { XCTAssertEqual(actual, status) }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    /// OAuth invalid_grant differs from transient HTTP errors, and never exposes provider text.
    func testRefreshFailureCategories() async throws {
        for (status, body) in [
            (400, #"{"error":"invalid_grant","error_description":"private"}"#), (503, "private"),
        ] {
            let server = Server([.init(status: status, body: body)])
            do {
                _ = try await ClaudeOAuthService.refresh(auth: auth(), transport: server.send)
                XCTFail("Expected refresh failure")
            } catch ClaudeAuthError.loginRequired {
                XCTAssertEqual(status, 400)
            } catch ClaudeAuthError.refreshHTTP(let actual) { XCTAssertEqual(actual, 503) }
        }
    }

    /// Invalid responses do not damage the old snapshot; missing expiry is genuinely unknown.
    func testRefreshResponseValidationAndOptionalFields() async throws {
        for body in [
            #"{"access_token":""}"#, #"{"access_token":"new","expires_in":true}"#,
            #"{"access_token":"new","expires_in":-1}"#,
        ] {
            let server = Server([.init(status: 200, body: body)])
            do {
                _ = try await ClaudeOAuthService.refresh(auth: auth(), transport: server.send)
                XCTFail("Expected response validation failure")
            } catch ClaudeAuthError.invalidResponse {}
        }
        let server = Server([.init(status: 200, body: #"{"access_token":"new"}"#)])
        let updated = try await ClaudeOAuthService.refresh(auth: auth(), transport: server.send)
        XCTAssertNil(updated.accessTokenExpiry)
        XCTAssertEqual(updated.oauth?.refreshToken, "old-refresh")
    }

    /// Rotation preserves unmodeled provider fields and refuses to overwrite a concurrent update.
    func testPersistencePreservesMetadataAndRejectsStaleWriter() throws {
        let original = auth()
        let fixture = try Fixture(auth: original)
        defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent(
            try XCTUnwrap(fixture.account.credentialSnapshot))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["futureCLIField"] = ["enabled": true]
        try SecureFileWriter.write(JSONSerialization.data(withJSONObject: object), to: url)
        let updated = auth("new", refresh: "rotated", expired: false)
        try fixture.store.persistRefreshedAuth(
            base: original, updated: updated, snapshot: fixture.account.credentialSnapshot)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(saved["futureCLIField"])
        XCTAssertThrowsError(
            try fixture.store.persistRefreshedAuth(
                base: original, updated: original, snapshot: fixture.account.credentialSnapshot)
        ) {
            guard case ClaudeAuthError.credentialChanged = $0 else { return XCTFail("Wrong error") }
        }
    }

    /// Keychain failure remains visible, while the rotated snapshot repairs live storage on retry.
    func testFailedKeychainWriteRetainsRotatedSnapshotForRecovery() throws {
        let original = auth()
        let fixture = try Fixture(auth: original, liveAuth: original)
        defer { fixture.cleanUp() }
        let raw = try JSONEncoder().encode(original)
        let denied = ClaudeCredentialStore(
            snapshotsDir: fixture.directory, fileURL: fixture.live,
            readKeychain: { raw }, saveKeychain: { _ in false })
        XCTAssertThrowsError(
            try denied.persistRefreshedAuth(
                base: original, updated: auth("new", refresh: "rotated", expired: false),
                snapshot: fixture.account.credentialSnapshot)
        ) {
            guard case ClaudeAuthError.persistence = $0 else { return XCTFail("Wrong error") }
        }
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "old-access")
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "new")
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "new")
    }
    /// A writable fallback must not hide a denied authoritative Keychain switch.
    func testActivationFailsWithoutChangingFallbackWhenKeychainDeniesWrite() throws {
        let original = auth()
        let fixture = try Fixture(auth: auth("selected"), liveAuth: original)
        defer { fixture.cleanUp() }
        let before = try Data(contentsOf: fixture.live)
        XCTAssertFalse(
            fixture.store.activate(snapshot: try XCTUnwrap(fixture.account.credentialSnapshot)))
        XCTAssertEqual(try Data(contentsOf: fixture.live), before)
    }

    /// An accepted Keychain switch mirrors the selected credential to the fallback.
    func testActivationMirrorsFallbackAfterKeychainAcceptsWrite() throws {
        let fixture = try Fixture(auth: auth("selected"), liveAuth: auth())
        defer { fixture.cleanUp() }
        let accepted = ClaudeCredentialStore(
            snapshotsDir: fixture.directory, fileURL: fixture.live,
            readKeychain: { nil },
            saveKeychain: { data in
                (try? JSONDecoder().decode(ClaudeAuth.self, from: data).accessToken) == "selected"
            })
        XCTAssertTrue(
            accepted.activate(snapshot: try XCTUnwrap(fixture.account.credentialSnapshot)))
        XCTAssertEqual(fixture.store.currentAuth()?.accessToken, "selected")
    }

    /// Re-read live credentials after 401 before rotating; the CLI may already have renewed them.
    func testCLIUpdateDuringUsageRequestRetriesWithoutTokenExchange() async throws {
        let fixture = try Fixture(auth: auth(expired: false))
        defer { fixture.cleanUp() }
        var newer = auth("cli-new", expired: false)
        newer.oauth?.expiresAt = Date().addingTimeInterval(14400).timeIntervalSince1970 * 1_000
        let newData = try JSONEncoder().encode(newer)
        let liveURL = fixture.live
        let server = Server([.init(status: 401, body: "{}"), .init(status: 200, body: usageBody)])
        _ = try await UsageService.fetchClaude(fixture.account, store: fixture.store) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                try SecureFileWriter.write(newData, to: liveURL)
            }
            return try await server.send(request)
        }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-new")
    }

    /// Empty live OAuth blobs do not prove ownership and must not be replaced from a snapshot.
    func testUnknownLiveIdentityIsNeverOverwritten() throws {
        let fixture = try Fixture(auth: auth())
        defer { fixture.cleanUp() }
        let empty = Data(#"{"claudeAiOauth":{}}"#.utf8)
        try SecureFileWriter.write(empty, to: fixture.live)
        _ = try fixture.store.auth(for: fixture.account)
        XCTAssertEqual(try Data(contentsOf: fixture.live), empty)
    }

    /// Concurrent callers for the same snapshot share one exchange; a later call fetches anew.
    func testConcurrentRefreshIsCoalesced() async throws {
        let fixture = try Fixture(auth: auth())
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 200, body: tokenBody), .init(status: 200, body: usageBody),
            .init(status: 200, body: usageBody),
        ])
        let store = fixture.store
        let coordinator = ClaudeUsageCoordinator { account in
            try await Task.sleep(for: .milliseconds(100))
            return try await UsageService.fetchClaude(account, store: store, transport: server.send)
        }
        try await withThrowingTaskGroup(of: Usage.self) { group in
            for _ in 0..<8 {
                group.addTask { try await coordinator.fetch(for: fixture.account) }
            }
            for try await result in group { XCTAssertEqual(result.fiveHour.usedFraction, 0.25) }
        }
        var requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        _ = try await coordinator.fetch(for: fixture.account)
        requests = await server.requests
        XCTAssertEqual(requests.count, 3)
    }

}
