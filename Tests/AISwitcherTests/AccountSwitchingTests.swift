import Foundation
import XCTest

@testable import AISwitcher

/// All credentials are synthetic; storage and usage transport are isolated from
/// the real CLI, Keychain and network.
@MainActor
final class AccountSwitchingTests: XCTestCase {
    private var directory: URL!
    private var snapshots: URL!
    private var live: URL!
    private var settings: URL!
    private var store: ClaudeCredentialStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        snapshots = directory.appendingPathComponent("snapshots", isDirectory: true)
        live = directory.appendingPathComponent("live.json")
        settings = directory.appendingPathComponent("claude.json")
        store = ClaudeCredentialStore(
            snapshotsDir: snapshots, fileURL: live,
            readKeychain: { nil }, saveKeychain: { _ in true },
            profiles: ClaudeProfileStore(fileURL: settings))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func identity(_ uuid: String, email: String) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(accountUUID: uuid, email: email)
    }

    private func credential(
        access: String, refresh: String, identity: ClaudeAccountIdentity?
    ) throws -> Data {
        var auth = ClaudeAuth(
            oauth: .init(
                accessToken: access, refreshToken: refresh,
                expiresAt: Date().addingTimeInterval(7_200).timeIntervalSince1970 * 1_000,
                scopes: ["user:profile"], subscriptionType: "pro"))
        auth.accountIdentity = identity
        return try JSONEncoder().encode(auth)
    }

    /// Write a synthetic copy of the account block Claude Code keeps in `~/.claude.json`.
    private func record(_ identity: ClaudeAccountIdentity) throws {
        struct Settings: Encodable { let oauthAccount: ClaudeAccountIdentity }
        try SecureFileWriter.write(
            JSONEncoder().encode(Settings(oauthAccount: identity)), to: settings)
    }

    private func savedAuth(for account: Account) throws -> ClaudeAuth {
        try store.auth(for: account)
    }

    // MARK: Switching

    /// Provider CLIs rotate tokens between launches, so the generation the switcher
    /// captured at startup is routinely stale by the time the user switches. Without
    /// a capture, overwriting the live credential would strand the outgoing account
    /// on a refresh token the provider has already retired.
    func testSwitchingCapturesARotationTheCLIPerformedBeforeOverwritingIt() async throws {
        let ada = identity("11111111-1111-1111-1111-111111111111", email: "ada@example.com")
        let bob = identity("22222222-2222-2222-2222-222222222222", email: "bob@example.com")
        let manager = AccountsManager(ephemeral: true, claudeStore: store) { _ in .empty }
        let adaAccount = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "ada-1", refresh: "ada-r1", identity: ada)
        ).account
        let bobAccount = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "bob-1", refresh: "bob-r1", identity: bob)
        ).account

        // Claude Code rotates Ada's live login out of band and records it as Ada's.
        try record(ada)
        try SecureFileWriter.write(
            credential(access: "ada-2", refresh: "ada-r2", identity: nil), to: live)

        await manager.activate(bobAccount)

        XCTAssertTrue(manager.isActive(bobAccount))
        XCTAssertEqual(
            try savedAuth(for: adaAccount).oauth?.refreshToken, "ada-r2",
            "The rotated generation must be captured before the slot is handed over")
        XCTAssertEqual(try savedAuth(for: adaAccount).accountIdentity, ada)
        XCTAssertEqual(store.currentAuth()?.accessToken, "bob-1")
        XCTAssertEqual(manager.accounts.count, 2, "A rotation is not a new account")
    }

    /// An out-of-band login the switcher has never seen is kept rather than discarded.
    func testSwitchingKeepsAnUnrecognizedLiveLogin() async throws {
        let ada = identity("11111111-1111-1111-1111-111111111111", email: "ada@example.com")
        let carol = identity("33333333-3333-3333-3333-333333333333", email: "carol@example.com")
        let manager = AccountsManager(ephemeral: true, claudeStore: store) { _ in .empty }
        let adaAccount = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "ada-1", refresh: "ada-r1", identity: ada)
        ).account
        try record(carol)
        try SecureFileWriter.write(
            credential(access: "carol-1", refresh: "carol-r1", identity: nil), to: live)

        await manager.activate(adaAccount)

        XCTAssertTrue(manager.isActive(adaAccount))
        let rescued = try XCTUnwrap(
            manager.accounts.first { $0.accountID == carol.accountID })
        XCTAssertEqual(rescued.label, "carol")
        XCTAssertEqual(try savedAuth(for: rescued).accessToken, "carol-1")
    }

    // MARK: Rejected credentials

    /// A rotated refresh token stays rejected until the credential changes. Presenting
    /// it again every five minutes is token reuse, which providers may answer by
    /// revoking the whole token family — including the login the CLI is still using.
    func testRejectedLoginIsNotRetriedUntilTheCredentialChanges() async throws {
        let ada = identity("11111111-1111-1111-1111-111111111111", email: "ada@example.com")
        let attempts = Counter()
        let manager = AccountsManager(ephemeral: true, claudeStore: store) { _ in
            await attempts.increment()
            throw ClaudeAuthError.loginRequired
        }
        let account = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "ada-1", refresh: "ada-r1", identity: ada)
        ).account

        await manager.refreshAll()
        var attempted = await attempts.count
        XCTAssertEqual(attempted, 1)
        XCTAssertNotNil(manager.refreshError(for: account))

        await manager.refreshAll()
        attempted = await attempts.count
        XCTAssertEqual(attempted, 1, "The timer must not replay a rejected token")
        XCTAssertNotNil(
            manager.refreshError(for: account), "The failure stays visible while latched")

        await manager.refreshAll(retryingRejectedLogins: true)
        attempted = await attempts.count
        XCTAssertEqual(attempted, 2, "An explicit refresh always retries")

        // A new generation — imported or adopted — releases the latch on its own.
        _ = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "ada-2", refresh: "ada-r2", identity: ada))
        await manager.refreshAll()
        attempted = await attempts.count
        XCTAssertEqual(attempted, 3)
    }

    /// Transient failures are not login failures and must keep being retried.
    func testTransientFailuresAreNotLatched() async throws {
        let ada = identity("11111111-1111-1111-1111-111111111111", email: "ada@example.com")
        let attempts = Counter()
        let manager = AccountsManager(ephemeral: true, claudeStore: store) { _ in
            await attempts.increment()
            throw ClaudeAuthError.network
        }
        _ = try await manager.importCredentialData(
            provider: .claude,
            data: credential(access: "ada-1", refresh: "ada-r1", identity: ada))
        await manager.refreshAll()
        await manager.refreshAll()
        let attempted = await attempts.count
        XCTAssertEqual(attempted, 2)
    }

    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }
}
