import Foundation
import XCTest

@testable import AISwitcher

/// Verifies drag-and-drop account ordering, provider section ordering,
/// disk persistence round-trips, and drop-target geometry calculations.
@MainActor
final class AccountReorderingTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let persistenceURL: URL
        let codexStore: CodexCredentialStore
        let claudeStore: ClaudeCredentialStore
        let geminiStore: GeminiCredentialStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            persistenceURL = directory.appendingPathComponent("accounts.json")
            codexStore = CodexCredentialStore(
                authURL: directory.appendingPathComponent("codex-auth.json"),
                snapshotsDir: directory.appendingPathComponent("codex-snaps", isDirectory: true)
            )
            claudeStore = ClaudeCredentialStore(
                snapshotsDir: directory.appendingPathComponent("claude-snaps", isDirectory: true),
                fileURL: directory.appendingPathComponent("claude-live.json"),
                readKeychain: { nil },
                saveKeychain: { _ in true },
                profiles: ClaudeProfileStore(
                    fileURL: directory.appendingPathComponent("claude.json"))
            )
            geminiStore = GeminiCredentialStore(
                authURL: directory.appendingPathComponent("gemini-auth.json"),
                accountsFileURL: directory.appendingPathComponent("google_accounts.json"),
                snapshotsDir: directory.appendingPathComponent("gemini-snaps", isDirectory: true)
            )
        }

        @MainActor
        func makeManager(ephemeral: Bool = false) -> AccountsManager {
            AccountsManager(
                ephemeral: ephemeral,
                persistenceURL: persistenceURL,
                claudeStore: claudeStore,
                codexStore: codexStore,
                geminiStore: geminiStore,
                fetchUsage: { _ in .empty }
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func codexData(id: String, access: String) throws -> Data {
        try JSONEncoder().encode(
            CodexAuth(tokens: .init(accessToken: access, refreshToken: "r-\(id)", accountID: id))
        )
    }

    private func geminiData(email: String, access: String) throws -> Data {
        try JSONEncoder().encode(
            GeminiAuth(accessToken: access, refreshToken: "r-\(email)", accountEmail: email)
        )
    }

    private func claudeData(uuid: String, email: String, access: String) throws -> Data {
        var auth = ClaudeAuth(
            oauth: .init(accessToken: access, refreshToken: "r-\(uuid)", subscriptionType: "pro"))
        auth.accountIdentity = ClaudeAccountIdentity(accountUUID: uuid, email: email)
        return try JSONEncoder().encode(auth)
    }

    func testReorderingAccountsWithinProviderPersistsAcrossReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let first = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-1", access: "a1")
        ).account
        let second = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-2", access: "a2")
        ).account
        let third = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-3", access: "a3")
        ).account
        let gemini = try await manager.importCredentialData(
            provider: .gemini, data: geminiData(email: "g@example.com", access: "g1")
        ).account

        XCTAssertEqual(manager.accounts(for: .codex).map(\.id), [first.id, second.id, third.id])

        // Move third account to the top of Codex section.
        manager.moveAccount(third.id, toIndexInProvider: 0)
        XCTAssertEqual(manager.accounts(for: .codex).map(\.id), [third.id, first.id, second.id])

        // Move first account to the bottom via List.onMove offset API.
        manager.moveAccounts(in: .codex, fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(manager.accounts(for: .codex).map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(
            manager.orderedAccounts.map(\.id),
            [third.id, second.id, first.id, gemini.id]
        )

        // Reload from disk and verify exact order survives restart.
        let reloaded = fixture.makeManager()
        XCTAssertEqual(reloaded.accounts(for: .codex).map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(
            reloaded.orderedAccounts.map(\.id),
            [third.id, second.id, first.id, gemini.id]
        )
    }

    func testReorderingProviderSectionsPersistsAndSynchronizesOrderedAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let codex = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-1", access: "a1")
        ).account
        let claude = try await manager.importCredentialData(
            provider: .claude, data: claudeData(uuid: "u1", email: "c@example.com", access: "c1")
        ).account
        let gemini1 = try await manager.importCredentialData(
            provider: .gemini, data: geminiData(email: "g1@example.com", access: "g1")
        ).account
        let gemini2 = try await manager.importCredentialData(
            provider: .gemini, data: geminiData(email: "g2@example.com", access: "g2")
        ).account

        XCTAssertEqual(manager.visibleProviders, [.codex, .claude, .gemini])

        // Drag Gemini section to the very top.
        manager.moveProvider(.gemini, toVisibleIndex: 0)
        XCTAssertEqual(manager.visibleProviders, [.gemini, .codex, .claude])
        XCTAssertEqual(
            manager.orderedAccounts.map(\.id),
            [gemini1.id, gemini2.id, codex.id, claude.id]
        )

        // Drag Codex section after Claude.
        manager.moveProvider(.codex, toVisibleIndex: 3)
        XCTAssertEqual(manager.visibleProviders, [.gemini, .claude, .codex])
        XCTAssertEqual(
            manager.orderedAccounts.map(\.id),
            [gemini1.id, gemini2.id, claude.id, codex.id]
        )

        let reloaded = fixture.makeManager()
        XCTAssertEqual(reloaded.visibleProviders, [.gemini, .claude, .codex])
        XCTAssertEqual(
            reloaded.orderedAccounts.map(\.id),
            [gemini1.id, gemini2.id, claude.id, codex.id]
        )
    }

    func testReorderingVisibleProvidersPreservesHiddenProviderSlot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        _ = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-1", access: "a1")
        )
        _ = try await manager.importCredentialData(
            provider: .gemini, data: geminiData(email: "g@example.com", access: "g1")
        )
        // Claude is hidden (no accounts); visible providers are [.codex, .gemini].
        XCTAssertEqual(manager.visibleProviders, [.codex, .gemini])

        manager.moveProvider(.gemini, toVisibleIndex: 0)
        XCTAssertEqual(manager.visibleProviders, [.gemini, .codex])
        XCTAssertEqual(manager.providerOrder, [.gemini, .claude, .codex])
    }

    func testReconcilingExistingAccountPreservesCustomOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let first = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-1", access: "a1")
        ).account
        let second = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-2", access: "a2")
        ).account

        manager.moveAccount(second.id, toIndexInProvider: 0)
        XCTAssertEqual(manager.accounts(for: .codex).map(\.id), [second.id, first.id])

        // Re-importing the updated credential for `first` updates it in place.
        _ = try await manager.importCredentialData(
            provider: .codex, data: codexData(id: "codex-1", access: "a1-rotated")
        )
        XCTAssertEqual(manager.accounts(for: .codex).map(\.id), [second.id, first.id])
    }

    func testLegacySnapshotWithoutProviderOrderDefaultsToAllCases() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let codex = Account(provider: .codex, label: "c1", plan: .pro, accountID: "c1")
        let gemini = Account(provider: .gemini, label: "g1", plan: .pro, accountID: "g1")
        let legacyJSON = try JSONEncoder().encode([
            "accounts": [gemini, codex]
        ])
        try legacyJSON.write(to: fixture.persistenceURL, options: .atomic)

        let loaded = fixture.makeManager()
        XCTAssertEqual(loaded.providerOrder, Provider.allCases)
        XCTAssertEqual(loaded.visibleProviders, [.codex, .gemini])
    }

    func testReorderGeometryCalculatesAccurateInsertionGapsForVariableHeights() {
        let ids = ["a", "b", "c"]
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 80),  // midY = 40
            "b": CGRect(x: 0, y: 88, width: 300, height: 140),  // midY = 158
            "c": CGRect(x: 0, y: 236, width: 300, height: 70),  // midY = 271
        ]

        XCTAssertEqual(
            ReorderGeometry.targetIndex(forDragY: 10, orderedIDs: ids, frames: frames), 0)
        XCTAssertEqual(
            ReorderGeometry.targetIndex(forDragY: 50, orderedIDs: ids, frames: frames), 1)
        XCTAssertEqual(
            ReorderGeometry.targetIndex(forDragY: 160, orderedIDs: ids, frames: frames), 2)
        XCTAssertEqual(
            ReorderGeometry.targetIndex(forDragY: 300, orderedIDs: ids, frames: frames), 3)

        XCTAssertFalse(ReorderGeometry.movesItem(from: 1, to: 1))
        XCTAssertFalse(ReorderGeometry.movesItem(from: 1, to: 2))
        XCTAssertTrue(ReorderGeometry.movesItem(from: 1, to: 0))
        XCTAssertTrue(ReorderGeometry.movesItem(from: 1, to: 3))
    }
}
