import Foundation
import XCTest

@testable import AISwitcher

/// Exercises Antigravity CLI (`agy`) `statusLine` hook installation, execution,
/// quota parsing, and `AccountsManager` synchronization using synthetic payloads.
@MainActor
final class AntigravityUsageTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let store: AntigravityUsageStore

        init() throws {
            // Include a space in the path to match macOS `Application Support`.
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AISwitcher Test \(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let appSupport = directory.appendingPathComponent(
                "Application Support/AISwitcher", isDirectory: true)
            store = AntigravityUsageStore(
                usageFileURL: appSupport.appendingPathComponent("antigravity-usage.json"),
                settingsURL: directory.appendingPathComponent("antigravity-cli/settings.json"),
                hookScriptURL: appSupport.appendingPathComponent("agy-statusline-hook.sh")
            )
        }

        func runHook(with stdinJSON: String) throws -> (status: Int32, stdout: String) {
            let process = Process()
            let inPipe = Pipe()
            let outPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", AntigravityUsageStore.shellQuoted(store.hookScriptURL.path)]
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
            inPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let output = String(
                decoding: outPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            return (process.terminationStatus, output)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    func testParseAntigravityQuotaPrefersGeminiBucketsAndPicksMostConstrained() throws {
        let recordedAt = try XCTUnwrap(ISO8601DateFormatter.parse("2026-11-22T08:00:00Z"))
        let snapshot = AntigravityUsageSnapshot(
            email: "dev@example.com",
            planTier: "Pro",
            quota: [
                "gemini-pro-5h": .init(
                    remainingFraction: 0.42,
                    resetTime: "2026-11-22T12:00:00Z"
                ),
                "gemini-flash-5h": .init(
                    remainingFraction: 0.88,
                    resetTime: "2026-11-22T13:00:00Z"
                ),
                "gemini-weekly": .init(
                    remainingFraction: 0.76,
                    resetTime: "2026-11-29T08:00:00Z",
                    resetInSeconds: 604_800
                ),
                "claude-5h": .init(
                    remainingFraction: 0.05,
                    resetTime: "2026-11-22T09:00:00Z"
                ),
                "gemini-disabled-5h": .init(
                    remainingFraction: 0.01,
                    resetTime: "2026-11-22T09:00:00Z",
                    disabled: true
                ),
            ],
            recordedAt: recordedAt
        )

        let usage = UsageService.parseAntigravityQuota(snapshot)

        XCTAssertEqual(try XCTUnwrap(usage.fiveHour.remainingFraction), 0.42, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay.remainingFraction), 0.76, accuracy: 0.000_1)
        XCTAssertEqual(
            usage.fiveHour.resetsAt, ISO8601DateFormatter.parse("2026-11-22T12:00:00Z"))
        XCTAssertEqual(
            usage.sevenDay.resetsAt, ISO8601DateFormatter.parse("2026-11-29T08:00:00Z"))
        XCTAssertEqual(usage.discoveredPlan, .pro)
    }

    func testParseAntigravityQuotaKeepsMissingWindowsUnknownAndSupportsResetInSeconds() throws {
        let recordedAt = try XCTUnwrap(ISO8601DateFormatter.parse("2026-11-22T08:00:00Z"))
        let snapshot = AntigravityUsageSnapshot(
            email: "dev@example.com",
            planTier: "Ultra",
            quota: [
                "gemini-weekly": .init(
                    remainingFraction: 0.9378,
                    resetTime: nil,
                    resetInSeconds: 560_580
                )
            ],
            recordedAt: recordedAt
        )

        let usage = UsageService.parseAntigravityQuota(snapshot)

        XCTAssertNil(usage.fiveHour.usedFraction)
        XCTAssertEqual(usage.fiveHour.remainingPercentText, "--%")
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay.remainingFraction), 0.9378, accuracy: 0.000_1)
        XCTAssertEqual(usage.sevenDay.resetsAt, recordedAt.addingTimeInterval(560_580))
        XCTAssertEqual(usage.discoveredPlan, .ultra)
    }

    func testInstallRecorderPreservesSettingsExecutesHookAndSanitizesPayload() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try FileManager.default.createDirectory(
            at: fixture.store.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalSettings = Data(
            #"{"model":"gemini-4-neon-xhigh","trustedWorkspaces":["/tmp/demo"],"statusLine":{"type":"command","command":"printf 'CUSTOM-LINE'"}}"#
                .utf8
        )
        try originalSettings.write(to: fixture.store.settingsURL)

        try fixture.store.installRecorder()
        XCTAssertTrue(fixture.store.isRecorderInstalled())

        // Reinstalling must be idempotent and keep the original chained command.
        try fixture.store.installRecorder()

        let settingsObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.settingsURL))
                as? [String: Any]
        )
        XCTAssertEqual(settingsObj["model"] as? String, "gemini-4-neon-xhigh")
        XCTAssertNotNil(settingsObj["trustedWorkspaces"])
        let statusLine = try XCTUnwrap(settingsObj["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["aiSwitcherPreviousCommand"] as? String, "printf 'CUSTOM-LINE'")

        let payload = """
            {
                "cwd": "/private/secret/repo",
                "transcript_path": "/private/transcript.jsonl",
                "conversation_title": "Top secret task",
                "product": "antigravity",
                "email": "alice@example.com",
                "plan_tier": "Pro",
                "quota": {
                    "gemini-5h": {
                        "remaining_fraction": 0.65,
                        "reset_time": "2026-11-22T15:00:00Z",
                        "reset_in_seconds": 14400
                    },
                    "gemini-weekly": {
                        "remaining_fraction": 0.91,
                        "reset_time": "2026-11-29T08:00:00Z",
                        "reset_in_seconds": 560580
                    }
                }
            }
            """
        let result = try fixture.runHook(with: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "CUSTOM-LINE")

        let rawSaved = try String(contentsOf: fixture.store.usageFileURL, encoding: .utf8)
        XCTAssertFalse(rawSaved.contains("Top secret task"))
        XCTAssertFalse(rawSaved.contains("/private/secret/repo"))
        XCTAssertFalse(rawSaved.contains("transcript.jsonl"))

        let permissions =
            try FileManager.default.attributesOfItem(atPath: fixture.store.usageFileURL.path)[
                .posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let file = try XCTUnwrap(fixture.store.loadFile())
        XCTAssertEqual(file.activeEmail, "alice@example.com")
        let alice = try XCTUnwrap(file.accounts["alice@example.com"])
        XCTAssertEqual(alice.planTier, "Pro")
        XCTAssertEqual(alice.quota["gemini-5h"]?.remainingFraction, 0.65)
        XCTAssertEqual(alice.quota["gemini-weekly"]?.remainingFraction, 0.91)
    }

    func testAccountsManagerSyncsMultipleAntigravityAccountsAndPreservesOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.store.installRecorder()
        _ = try fixture.runHook(
            with:
                #"{"email":"alice@example.com","plan_tier":"Pro","quota":{"gemini-5h":{"remaining_fraction":0.7},"gemini-weekly":{"remaining_fraction":0.8}}}"#
        )
        _ = try fixture.runHook(
            with:
                #"{"email":"bob@example.com","plan_tier":"Ultra","quota":{"gemini-5h":{"remaining_fraction":0.4},"gemini-weekly":{"remaining_fraction":0.9}}}"#
        )

        let manager = AccountsManager(
            ephemeral: true,
            antigravityStore: fixture.store,
            fetchUsage: { _ in .empty }
        )
        let synced = manager.syncAntigravityAccounts()
        XCTAssertEqual(synced.count, 2)
        XCTAssertEqual(manager.accounts(for: .gemini).map(\.label), ["alice", "bob"])

        let bob = try XCTUnwrap(manager.accounts.first { $0.label == "bob" })
        let alice = try XCTUnwrap(manager.accounts.first { $0.label == "alice" })
        XCTAssertTrue(manager.isActive(bob))
        XCTAssertEqual(bob.plan, .ultra)
        XCTAssertEqual(try XCTUnwrap(bob.usage.fiveHour.remainingFraction), 0.4, accuracy: 0.000_1)

        // Custom order and rename must survive subsequent sync and refreshAll().
        manager.moveAccount(bob.id, toIndexInProvider: 0)
        XCTAssertTrue(manager.rename(alice, to: "Alice Work"))

        _ = try fixture.runHook(
            with:
                #"{"email":"bob@example.com","plan_tier":"Ultra","quota":{"gemini-5h":{"remaining_fraction":0.25},"gemini-weekly":{"remaining_fraction":0.85}}}"#
        )
        await manager.refreshAll()

        XCTAssertEqual(manager.accounts(for: .gemini).map(\.id), [bob.id, alice.id])
        XCTAssertEqual(manager.accounts.first { $0.id == alice.id }?.displayLabel, "Alice Work")
        let updatedBob = try XCTUnwrap(manager.accounts.first { $0.id == bob.id })
        XCTAssertEqual(
            try XCTUnwrap(updatedBob.usage.fiveHour.remainingFraction), 0.25, accuracy: 0.000_1)

        // Removing an inactive agy account also clears it from the local cache.
        XCTAssertTrue(manager.remove(alice))
        XCTAssertNil(fixture.store.snapshot(forEmail: "alice@example.com"))
    }
}
