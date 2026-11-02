import Foundation
import XCTest

@testable import AISwitcher

/// All credentials are synthetic; storage and HTTP transport are isolated from the real CLI.
@MainActor
final class ClaudeAuthenticationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        /// Managed snapshot directory, kept apart from the live and settings files
        /// so neither is ever mistaken for a managed credential.
        let snapshots: URL
        let live: URL
        let settings: URL
        let store: ClaudeCredentialStore
        let account: Account

        init(
            auth: ClaudeAuth,
            liveAuth: ClaudeAuth? = nil,
            recorded: ClaudeAccountIdentity? = nil
        ) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            snapshots = directory.appendingPathComponent("snapshots", isDirectory: true)
            live = directory.appendingPathComponent("live.json")
            settings = directory.appendingPathComponent("claude.json")
            store = ClaudeCredentialStore(
                snapshotsDir: snapshots, fileURL: live,
                readKeychain: { nil }, saveKeychain: { _ in false },
                profiles: ClaudeProfileStore(fileURL: settings))
            let accountID =
                try auth.accountIdentity.map { $0.accountID }
                ?? XCTUnwrap(store.stableAccountID(for: auth))
            let filename = try XCTUnwrap(
                store.snapshot(data: JSONEncoder().encode(auth), accountID: accountID))
            account = Account(
                provider: .claude, label: "Test", plan: .max, accountID: accountID,
                credentialSnapshot: filename)
            if let liveAuth { try SecureFileWriter.write(JSONEncoder().encode(liveAuth), to: live) }
            if let recorded { try Fixture.record(recorded, to: settings) }
        }

        /// Write a synthetic copy of the account block Claude Code keeps in `~/.claude.json`.
        static func record(_ identity: ClaudeAccountIdentity, to url: URL) throws {
            struct Settings: Encodable {
                let numStartups: Int
                let oauthAccount: ClaudeAccountIdentity
            }
            try SecureFileWriter.write(
                JSONEncoder().encode(Settings(numStartups: 7, oauthAccount: identity)), to: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func identity(
        _ uuid: String = "11111111-2222-3333-4444-555555555555", email: String? = "ada@example.com"
    ) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(accountUUID: uuid, email: email, displayName: "Ada Lovelace")
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
        let url = fixture.snapshots.appendingPathComponent(
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
            snapshotsDir: fixture.snapshots, fileURL: fixture.live,
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
            snapshotsDir: fixture.snapshots, fileURL: fixture.live,
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

    // MARK: Multiple Keychain items

    func testKeychainCandidateOrderPrefersUserThenNewest() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(
            ClaudeKeychainStore.candidateOrder(
                [("other", new), ("me", old), ("third", nil), ("older", old)], user: "me"),
            [1, 0, 3, 2])
        XCTAssertEqual(
            ClaudeKeychainStore.candidateOrder([("a", old), ("b", new)], user: "me"), [1, 0])
        XCTAssertEqual(ClaudeKeychainStore.candidateOrder([("only", nil)], user: "me"), [0])
    }

    func testKeychainLoginDetectionIgnoresMcpOnlyBlobs() {
        let login = Data(#"{"claudeAiOauth":{"accessToken":"synthetic"},"mcpOAuth":{}}"#.utf8)
        let mcpOnly = Data(#"{"mcpOAuth":{"server":{"accessToken":"synthetic"}}}"#.utf8)
        let empty = Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
        XCTAssertTrue(ClaudeKeychainStore.containsClaudeLogin(login))
        XCTAssertFalse(ClaudeKeychainStore.containsClaudeLogin(mcpOnly))
        XCTAssertFalse(ClaudeKeychainStore.containsClaudeLogin(empty))
        XCTAssertFalse(ClaudeKeychainStore.containsClaudeLogin(Data("not json".utf8)))
    }

    // MARK: Account identity

    /// Claude Code's own account record is the only identity the credential lacks.
    func testRecordedIdentityIsReadFromClaudeCodeSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude.json")
        let profiles = ClaudeProfileStore(fileURL: url)
        XCTAssertNil(profiles.liveIdentity())
        try Fixture.record(identity(), to: url)
        let recorded = try XCTUnwrap(profiles.liveIdentity())
        XCTAssertEqual(recorded.accountUUID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(recorded.email, "ada@example.com")
        XCTAssertEqual(recorded.accountID, "claude-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(recorded.label, "ada")
        try SecureFileWriter.write(Data(#"{"numStartups":7}"#.utf8), to: url)
        XCTAssertNil(profiles.liveIdentity())
    }

    /// A rotation must not rename the account; only a token-only fallback may change.
    func testIdentifierSurvivesRotationOnlyWithARecordedIdentity() throws {
        let fixture = try Fixture(auth: auth())
        defer { fixture.cleanUp() }
        var rotated = auth("rotated-access", refresh: "rotated-refresh")
        XCTAssertNotEqual(
            fixture.store.stableAccountID(for: auth()),
            fixture.store.stableAccountID(for: rotated))
        var original = auth()
        original.accountIdentity = identity()
        rotated.accountIdentity = identity()
        XCTAssertEqual(
            fixture.store.stableAccountID(for: original),
            "claude-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(
            fixture.store.stableAccountID(for: original),
            fixture.store.stableAccountID(for: rotated))
    }

    /// Claude Code rotating both tokens is the same account, and its new generation
    /// must replace the snapshot instead of provoking a refresh of a consumed token.
    func testCLIRotationIsAdoptedWhenTheRecordedIdentityMatches() async throws {
        var saved = auth()
        saved.accountIdentity = identity()
        let fixture = try Fixture(
            auth: saved, liveAuth: auth("cli-access", refresh: "cli-refresh", expired: false),
            recorded: identity())
        defer { fixture.cleanUp() }
        let server = Server([.init(status: 200, body: usageBody)])
        _ = try await UsageService.fetchClaude(
            fixture.account, store: fixture.store, transport: server.send)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1, "The superseded refresh token must never be replayed")
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer cli-access")
        let adopted = try fixture.store.auth(for: fixture.account)
        XCTAssertEqual(adopted.oauth?.refreshToken, "cli-refresh")
        XCTAssertEqual(adopted.accountIdentity, identity(), "Identity outlives the rotation")
    }

    /// A different recorded account is not a rotation and must not be adopted.
    func testCLIRotationIsRefusedForADifferentRecordedAccount() throws {
        var saved = auth()
        saved.accountIdentity = identity()
        let fixture = try Fixture(
            auth: saved, liveAuth: auth("other-access", refresh: "other-refresh", expired: false),
            recorded: identity("99999999-8888-7777-6666-555555555555", email: "bob@example.com"))
        defer { fixture.cleanUp() }
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "old-access")
    }

    /// After the switcher activates a snapshot, Claude Code's record still names the
    /// account it replaced. An owned live credential therefore outranks that record.
    func testStaleRecordedIdentityIsIgnoredWhileAnotherSnapshotOwnsLive() throws {
        var saved = auth()
        saved.accountIdentity = identity()
        let live = auth("switched-access", refresh: "switched-refresh", expired: false)
        let fixture = try Fixture(auth: saved, liveAuth: live, recorded: identity())
        defer { fixture.cleanUp() }
        var other = live
        other.accountIdentity = identity("99999999-8888-7777-6666-555555555555", email: nil)
        XCTAssertNotNil(
            fixture.store.snapshot(
                data: try JSONEncoder().encode(other),
                accountID: try XCTUnwrap(fixture.store.stableAccountID(for: other))))
        XCTAssertEqual(try fixture.store.auth(for: fixture.account).accessToken, "old-access")
    }

    /// Managed metadata is the switcher's own bookkeeping and must never reach the CLI.
    func testActivationNeverWritesManagedMetadataIntoTheLiveCredential() throws {
        var saved = auth("selected", expired: false)
        saved.accountIdentity = identity()
        let fixture = try Fixture(auth: saved)
        defer { fixture.cleanUp() }
        let written = Captured()
        let accepted = ClaudeCredentialStore(
            snapshotsDir: fixture.snapshots, fileURL: fixture.live,
            readKeychain: { nil }, saveKeychain: { written.store($0) },
            profiles: ClaudeProfileStore(fileURL: fixture.settings))
        XCTAssertTrue(
            accepted.activate(snapshot: try XCTUnwrap(fixture.account.credentialSnapshot)))
        for data in [try XCTUnwrap(written.value), try Data(contentsOf: fixture.live)] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["aiSwitcherAccountIdentity"])
            XCTAssertNil(object["aiSwitcherPreviousCredentialFingerprint"])
            XCTAssertEqual(
                (object["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "selected")
        }
        XCTAssertEqual(
            try fixture.store.auth(for: fixture.account).accountIdentity, identity(),
            "The snapshot keeps the identity it lent to the live credential")
    }

    /// A switcher-performed rotation must not drop the identity it resolved earlier.
    func testRotationKeepsTheManagedIdentityInTheSnapshot() throws {
        var original = auth()
        original.accountIdentity = identity()
        let fixture = try Fixture(auth: original)
        defer { fixture.cleanUp() }
        try fixture.store.persistRefreshedAuth(
            base: original, updated: auth("new", refresh: "rotated", expired: false),
            snapshot: fixture.account.credentialSnapshot)
        let saved = try fixture.store.auth(for: fixture.account)
        XCTAssertEqual(saved.oauth?.refreshToken, "rotated")
        XCTAssertEqual(saved.accountIdentity, identity())
    }

    /// Captures the bytes a synthetic Keychain writer accepted.
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        var value: Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func store(_ incoming: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            data = incoming
            return true
        }
    }
}
