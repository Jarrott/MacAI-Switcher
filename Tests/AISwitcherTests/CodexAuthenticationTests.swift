import Foundation
import XCTest

@testable import AISwitcher

/// Synthetic credentials and isolated directories exercise recovery without real provider requests.
@MainActor
final class CodexAuthenticationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: CodexCredentialStore
        let account: Account

        init(_ auth: CodexAuth, live: CodexAuth? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            store = CodexCredentialStore(
                authURL: directory.appendingPathComponent("auth.json"),
                snapshotsDir: directory.appendingPathComponent("snapshots"))
            let id = try XCTUnwrap(auth.accountID)
            let snapshot = try XCTUnwrap(
                store.snapshot(data: JSONEncoder().encode(auth), accountID: id))
            account = Account(
                provider: .codex, label: "Test", plan: .pro, accountID: id,
                credentialSnapshot: snapshot)
            if let live {
                try SecureFileWriter.write(JSONEncoder().encode(live), to: store.authURL)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Scripted provider replies reject unexpected calls and record only synthetic credential bytes.
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
            guard !replies.isEmpty else { throw CodexAuthError.invalidResponse }
            let reply = replies.removeFirst()
            return (
                Data(reply.body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    private let usageBody =
        #"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"#
    private let tokenBody = #"{"access_token":"new-access","refresh_token":"new-refresh"}"#
    private let request = URLRequest(url: URL(string: "https://example.invalid/usage")!)

    private func auth(
        _ access: String = "old-access", refresh: String = "old-refresh", id: String = "account-a",
        expired: Bool = false
    ) -> CodexAuth {
        var access = access
        if expired {
            let body = Data(#"{"exp":1}"#.utf8).base64EncodedString()
            access = "header.\(body).signature"
        }
        return CodexAuth(tokens: .init(accessToken: access, refreshToken: refresh, accountID: id))
    }

    private func fetch(_ fixture: Fixture, server: Server) async throws -> Usage {
        try await UsageService.fetchCodex(
            fixture.account,
            coordinator: CodexAuthCoordinator(store: fixture.store, transport: server.send),
            transport: server.send)
    }

    func testMatchingLiveRotationRepairsSnapshotWithoutOAuth() async throws {
        let fixture = try Fixture(
            auth(expired: true), live: auth("cli-access", refresh: "cli-refresh"))
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: usageBody), .init(status: 503, body: "{}")])
        let usage = try await fetch(fixture, server: server)
        XCTAssertEqual(usage.fiveHour.usedFraction, 0.25)
        XCTAssertNil(usage.resetsAvailable, "Unavailable credits must never become zero")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
        XCTAssertEqual(
            fixture.store.loadSnapshot(fixture.account.credentialSnapshot!)?.tokens?.refreshToken,
            "cli-refresh")
    }

    func test401RefreshesOnceAndRetriesWithPersistedCredential() async throws {
        let fixture = try Fixture(auth(), live: auth())
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 401, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 200, body: usageBody),
            .init(status: 200, body: #"{"available_count":2}"#),
        ])
        let usage = try await fetch(fixture, server: server)
        XCTAssertEqual(usage.resetsAvailable, 2)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(
            try fixture.store.auth(for: fixture.account).tokens?.refreshToken, "new-refresh")
        XCTAssertEqual(fixture.store.currentAuth()?.tokens?.accessToken, "new-access")
        let liveData = try Data(contentsOf: fixture.store.authURL)
        XCTAssertFalse(String(decoding: liveData, as: UTF8.self).contains("aiSwitcherPrevious"))
        let permissions =
            try FileManager.default.attributesOfItem(atPath: fixture.store.authURL.path)[
                .posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func test401AfterProactiveRefreshNeverReusesOldRefreshToken() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: tokenBody), .init(status: 401, body: "{}")])
        do {
            _ = try await fetch(fixture, server: server)
            XCTFail("Expected loginRequired")
        } catch CodexAuthError.loginRequired {}
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            try fixture.store.auth(for: fixture.account).tokens?.refreshToken, "new-refresh")
    }

    func testRepeated401StopsAfterOneRetry() async throws {
        let fixture = try Fixture(auth())
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 401, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 401, body: "{}"),
        ])
        do {
            _ = try await fetch(fixture, server: server)
            XCTFail("Expected loginRequired")
        } catch CodexAuthError.loginRequired {}
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
    }

    func test403And429DoNotRefreshTokens() async throws {
        for status in [403, 429] {
            let fixture = try Fixture(auth())
            defer { fixture.cleanUp() }
            let server = Server([.init(status: status, body: "{}")])
            do {
                _ = try await fetch(fixture, server: server)
                XCTFail("Expected HTTP failure")
            } catch UsageService.FetchError.http(let value) { XCTAssertEqual(value, status) }
            let requests = await server.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testInactiveAccountNeverUsesOrOverwritesOtherLiveLogin() async throws {
        let other = auth("other-access", refresh: "other-refresh", id: "account-b")
        let fixture = try Fixture(auth(expired: true), live: other)
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: tokenBody), .init(status: 200, body: "{}")])
        let coordinator = CodexAuthCoordinator(store: fixture.store, transport: server.send)
        _ = try await coordinator.send(request, for: fixture.account)
        XCTAssertEqual(fixture.store.currentAuth(), other)
        let requests = await server.requests
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "chatgpt-account-id"), "account-a")
    }

    func testMissingAndUnsafeSnapshotsNeverUseAnotherAccount() throws {
        let fixture = try Fixture(auth(), live: auth(id: "account-b"))
        defer { fixture.cleanUp() }
        var missing = fixture.account
        missing.credentialSnapshot = "missing.json"
        XCTAssertThrowsError(try fixture.store.auth(for: missing))
        missing.credentialSnapshot = "../auth.json"
        XCTAssertThrowsError(try fixture.store.auth(for: missing))
        missing.credentialSnapshot = nil
        XCTAssertThrowsError(try fixture.store.auth(for: missing))
    }

    func testRejectedRefreshIsLatchedUntilCredentialChanges() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 400, body: #"{"error":{"code":"refresh_token_reused"}}"#),
            .init(status: 200, body: "{}"),
        ])
        let coordinator = CodexAuthCoordinator(store: fixture.store, transport: server.send)
        for _ in 0..<2 {
            do {
                _ = try await coordinator.send(request, for: fixture.account)
                XCTFail("Expected rejected login")
            } catch CodexAuthError.loginRequired {}
        }
        var requests = await server.requests
        XCTAssertEqual(requests.count, 1)
        try SecureFileWriter.write(
            JSONEncoder().encode(auth("cli-access", refresh: "cli-refresh")),
            to: fixture.store.authURL)
        _ = try await coordinator.send(request, for: fixture.account)
        requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
    }

    func testTransientRefreshFailureCanRetry() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server([
            .init(status: 503, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 200, body: "{}"),
        ])
        let coordinator = CodexAuthCoordinator(store: fixture.store, transport: server.send)
        do {
            _ = try await coordinator.send(request, for: fixture.account)
            XCTFail("Expected temporary failure")
        } catch CodexAuthError.refreshHTTP(let status) { XCTAssertEqual(status, 503) }
        _ = try await coordinator.send(request, for: fixture.account)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testConcurrentOperationsShareOneExchange() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let server = Server(
            [.init(status: 200, body: tokenBody)]
                + Array(repeating: .init(status: 200, body: "{}"), count: 12))
        let coordinator = CodexAuthCoordinator(store: fixture.store) { request in
            let response = try await server.send(request)
            if request.url == TokenRefresher.codexTokenURL {
                try await Task.sleep(for: .milliseconds(50))
            }
            return response
        }
        let request = self.request
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await coordinator.send(request, for: fixture.account) }
            }
            try await group.waitForAll()
        }
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0.url == TokenRefresher.codexTokenURL }.count, 1)
        XCTAssertEqual(requests.count, 13)
    }

    func testCLIRotationDuring401AvoidsExchangingOldToken() async throws {
        let fixture = try Fixture(auth())
        defer { fixture.cleanUp() }
        let replacement = auth("cli-access", refresh: "cli-refresh")
        let server = Server([.init(status: 401, body: "{}"), .init(status: 200, body: "{}")])
        let coordinator = CodexAuthCoordinator(store: fixture.store) { request in
            let response = try await server.send(request)
            if response.1.statusCode == 401 {
                try SecureFileWriter.write(
                    JSONEncoder().encode(replacement), to: fixture.store.authURL)
            }
            return response
        }
        _ = try await coordinator.send(request, for: fixture.account)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
    }

    func testRotationObservedDuringFailedExchangeRecovers() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let replacement = auth("cli-access", refresh: "cli-refresh")
        let server = Server([
            .init(status: 400, body: #"{"error":"invalid_grant"}"#), .init(status: 200, body: "{}"),
        ])
        let coordinator = CodexAuthCoordinator(store: fixture.store) { request in
            let response = try await server.send(request)
            if request.url == TokenRefresher.codexTokenURL {
                try SecureFileWriter.write(
                    JSONEncoder().encode(replacement), to: fixture.store.authURL)
            }
            return response
        }
        _ = try await coordinator.send(request, for: fixture.account)
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).tokens, replacement.tokens)
    }

    func testFailedLiveWriteRecoversSavedRotationWithoutAnotherExchange() async throws {
        let base = auth(expired: true)
        let fixture = try Fixture(base, live: base)
        defer { fixture.cleanUp() }
        let backup = fixture.store.authURL.appendingPathExtension("switcher-bak")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let server = Server([.init(status: 200, body: tokenBody), .init(status: 200, body: "{}")])
        let coordinator = CodexAuthCoordinator(store: fixture.store, transport: server.send)
        do {
            _ = try await coordinator.send(request, for: fixture.account)
            XCTFail("Expected persistence failure")
        } catch CodexAuthError.persistence {}
        XCTAssertEqual(fixture.store.currentAuth()?.tokens, base.tokens)
        XCTAssertEqual(
            fixture.store.loadSnapshot(fixture.account.credentialSnapshot!)?.tokens?.refreshToken,
            "new-refresh")
        try FileManager.default.removeItem(at: backup)
        XCTAssertNotNil(fixture.store.snapshotCurrent(accountID: "account-a"))
        _ = try await coordinator.send(request, for: fixture.account)
        XCTAssertEqual(fixture.store.currentAuth()?.tokens?.refreshToken, "new-refresh")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
    }

    /// A failed snapshot write must retain the exchanged token in memory for a storage retry.
    func testFailedSnapshotWriteDoesNotExchangeRetiredTokenAgain() async throws {
        let fixture = try Fixture(auth())
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fixture.store.snapshotsDir.path)
            fixture.cleanUp()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fixture.store.snapshotsDir.path)
        let server = Server([
            .init(status: 401, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 200, body: "{}"),
        ])
        let coordinator = CodexAuthCoordinator(store: fixture.store, transport: server.send)
        do {
            _ = try await coordinator.send(request, for: fixture.account)
            XCTFail("Expected snapshot persistence failure")
        } catch CodexAuthError.persistence {}
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.store.snapshotsDir.path)
        _ = try await coordinator.send(request, for: fixture.account)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            try fixture.store.auth(for: fixture.account).tokens?.refreshToken, "new-refresh")
    }

    func testChangedSnapshotCannotBeOverwrittenByInFlightExchange() async throws {
        let fixture = try Fixture(auth(expired: true))
        defer { fixture.cleanUp() }
        let replacement = auth("signed-in", refresh: "signed-in-refresh")
        let server = Server([.init(status: 200, body: tokenBody)])
        let coordinator = CodexAuthCoordinator(store: fixture.store) { request in
            let response = try await server.send(request)
            _ = fixture.store.snapshot(
                data: try JSONEncoder().encode(replacement), accountID: "account-a")
            return response
        }
        do {
            _ = try await coordinator.send(request, for: fixture.account)
            XCTFail("Expected credential conflict")
        } catch CodexAuthError.credentialChanged {}
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).tokens, replacement.tokens)
    }

    func testResetRetryPreservesIdempotencyKeyAndBody() async throws {
        let fixture = try Fixture(auth())
        defer { fixture.cleanUp() }
        var account = fixture.account
        account.usage.resetsAvailable = 1
        let key = UUID()
        let server = Server([
            .init(status: 401, body: "{}"), .init(status: 200, body: tokenBody),
            .init(status: 200, body: #"{"status":"reset"}"#),
        ])
        let result = try await UsageService.consumeResetCredit(
            for: account, creditID: "synthetic-credit", idempotencyKey: key,
            coordinator: CodexAuthCoordinator(store: fixture.store, transport: server.send))
        XCTAssertEqual(result, .reset)
        let requests = await server.requests
        XCTAssertEqual(requests[0].httpBody, requests[2].httpBody)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String])
        XCTAssertEqual(body["redeem_request_id"], key.uuidString.lowercased())
        XCTAssertEqual(body["credit_id"], "synthetic-credit")
    }

    func testInvalidRefreshResponsesAndOmittedOptionalTokens() async throws {
        for body in [#"{"access_token":""}"#, #"{"access_token":"ok","refresh_token":""}"#, "{}"] {
            let server = Server([.init(status: 200, body: body)])
            do {
                _ = try await TokenRefresher.refreshCodex(auth: auth(), transport: server.send)
                XCTFail("Expected invalid response")
            } catch CodexAuthError.invalidResponse {}
        }
        let server = Server([.init(status: 200, body: #"{"access_token":"new-access"}"#)])
        let updated = try await TokenRefresher.refreshCodex(auth: auth(), transport: server.send)
        XCTAssertEqual(updated.tokens?.refreshToken, "old-refresh")
    }

    func testPersistencePreservesUnknownFields() throws {
        let base = auth()
        let fixture = try Fixture(base, live: base)
        defer { fixture.cleanUp() }
        let data = Data(
            #"{"tokens":{"access_token":"old-access","refresh_token":"old-refresh","account_id":"account-a","future_token_field":true},"future_root_field":"retained"}"#
                .utf8)
        _ = fixture.store.snapshot(data: data, accountID: "account-a")
        try fixture.store.persistRefreshedAuth(
            base: base, updated: auth("new-access", refresh: "new-refresh"), for: fixture.account)
        let live = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.authURL))
                as? [String: Any])
        XCTAssertEqual(live["future_root_field"] as? String, "retained")
        XCTAssertEqual((live["tokens"] as? [String: Any])?["future_token_field"] as? Bool, true)
    }

    func testReauthorizationUpdatesExistingAccountWithoutRemoval() async throws {
        let fixture = try Fixture(auth())
        defer { fixture.cleanUp() }
        let manager = AccountsManager(ephemeral: true, codexStore: fixture.store) { _ in
            Usage(
                fiveHour: .init(usedFraction: 0.25, resetsAt: nil), sevenDay: .unknown,
                resetsAvailable: nil, fetchedAt: Date())
        }
        let original = try await manager.importCredentialData(
            provider: .codex, data: JSONEncoder().encode(auth()), activate: true
        ).account
        XCTAssertTrue(manager.rename(original, to: "Work login"))
        await manager.refreshAll()
        let updated = try await manager.importCredentialData(
            provider: .codex,
            data: JSONEncoder().encode(auth("signed-in", refresh: "signed-in-refresh")),
            activate: true
        ).account
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.customLabel, "Work login")
        XCTAssertEqual(updated.usage.fiveHour.usedFraction, 0.25)
        XCTAssertTrue(manager.isActive(updated))
        XCTAssertEqual(fixture.store.currentAuth()?.tokens?.accessToken, "signed-in")
    }
}
