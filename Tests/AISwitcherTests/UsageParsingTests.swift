import AppKit
import Foundation
import XCTest

@testable import AISwitcher

final class UsageParsingTests: XCTestCase {
    /// The Codex backend may reverse or omit windows; classification must use
    /// `limit_window_seconds` instead of trusting primary/secondary position.
    func testCodexWindowsAreClassifiedByDuration() throws {
        let payload: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 82.0,
                    "limit_window_seconds": UsageService.weeklyWindowSeconds,
                    "reset_at": 1_800_000_000.0,
                ],
                "secondary_window": [
                    "used_percent": 7.0,
                    "limit_window_seconds": UsageService.sessionWindowSeconds,
                    "reset_at": 1_700_000_000.0,
                ],
            ]
        ]

        let usage = UsageService.parseCodex(payload)

        XCTAssertEqual(try XCTUnwrap(usage.fiveHour.usedFraction), 0.07, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay.usedFraction), 0.82, accuracy: 0.000_1)
        XCTAssertEqual(
            usage.fiveHour.resetsAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Claude reports utilization on a 0...100 scale and ISO-8601 reset dates.
    func testClaudeUsageScaleAndFractionalResetDate() throws {
        let payload: [String: Any] = [
            "five_hour": [
                "utilization": 12.5,
                "resets_at": "2026-08-09T10:11:12.123Z",
            ],
            "seven_day": [
                "utilization": 91,
                "resets_at": "2026-08-10T10:11:12Z",
            ],
        ]

        let usage = UsageService.parseClaude(payload)

        XCTAssertEqual(try XCTUnwrap(usage.fiveHour.usedFraction), 0.125, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay.usedFraction), 0.91, accuracy: 0.000_1)
        XCTAssertNotNil(usage.fiveHour.resetsAt)
        XCTAssertNotNil(usage.sevenDay.resetsAt)
    }

    /// The UI reports remaining capacity while provider payloads report consumed capacity.
    func testUsageWindowDisplaysRemainingPercentage() {
        XCTAssertEqual(UsageWindow(usedFraction: 0.93, resetsAt: nil).remainingPercentText, "7%")
        XCTAssertEqual(UsageWindow(usedFraction: 0.19, resetsAt: nil).remainingPercentText, "81%")
        XCTAssertEqual(UsageWindow(usedFraction: 1.7, resetsAt: nil).remainingPercentText, "0%")
        XCTAssertEqual(UsageWindow(usedFraction: -0.2, resetsAt: nil).remainingPercentText, "100%")
        XCTAssertEqual(
            UsageWindow(usedFraction: .infinity, resetsAt: nil).remainingPercentText,
            "--%"
        )
    }

    /// Remaining-quota risk colors use stable, inclusive threshold boundaries.
    func testRemainingQuotaLevelThresholds() {
        XCTAssertEqual(UsageWindow.unknown.remainingQuotaLevel, .unavailable)
        XCTAssertEqual(
            UsageWindow(usedFraction: 0.91, resetsAt: nil).remainingQuotaLevel,
            .critical
        )
        XCTAssertEqual(
            UsageWindow(usedFraction: 0.90, resetsAt: nil).remainingQuotaLevel,
            .warning
        )
        XCTAssertEqual(
            UsageWindow(usedFraction: 0.50, resetsAt: nil).remainingQuotaLevel,
            .warning
        )
        XCTAssertEqual(
            UsageWindow(usedFraction: 0.49, resetsAt: nil).remainingQuotaLevel,
            .healthy
        )
    }

    /// Email local-part matches the labels used by the reference account switcher.
    func testCodexLabelPrefersEmailLocalPartOverProfileName() {
        XCTAssertEqual(
            AccountsManager.preferredCodexLabel(
                email: "tmtdeveloper1@example.com",
                name: "Ho Developer"
            ),
            "tmtdeveloper1"
        )
        XCTAssertEqual(
            AccountsManager.preferredCodexLabel(email: nil, name: "JO Developer"),
            "JO"
        )
    }

    /// Add Account must present the authentication subcommand, not launch a chat session.
    func testProviderLoginCommands() {
        XCTAssertEqual(Provider.codex.cliExecutableName, "codex")
        XCTAssertEqual(Provider.codex.cliLoginArguments, ["login"])
        XCTAssertEqual(Provider.codex.loginCommand, "codex login")
        XCTAssertEqual(Provider.claude.cliExecutableName, "claude")
        XCTAssertEqual(Provider.claude.cliLoginArguments, ["auth", "login"])
        XCTAssertEqual(Provider.claude.loginCommand, "claude auth login")
    }

    /// GUI launches must expose the CLI's adjacent runtime before the minimal system PATH.
    func testBrowserLoginEnvironmentPrependsExecutableDirectory() {
        let executable = URL(fileURLWithPath: "/custom/nvm/bin/codex")
        let environment = CLIBrowserLoginService.processEnvironment(
            executableURL: executable,
            inherited: ["PATH": "/usr/bin:/custom/nvm/bin", "LANG": "en_US.UTF-8"]
        )
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths?.first, "/custom/nvm/bin")
        XCTAssertEqual(paths?.filter { $0 == "/custom/nvm/bin" }.count, 1)
        XCTAssertTrue(paths?.contains("/opt/homebrew/bin") == true)
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
    }

    /// Codex OAuth must use a private home so cancellation cannot clear the live login.
    func testBrowserLoginIsolationIsEnabledForCodexOnly() {
        XCTAssertEqual(
            CLIBrowserLoginService.isolatedHomeEnvironmentVariable(for: .codex),
            "CODEX_HOME"
        )
        XCTAssertNil(CLIBrowserLoginService.isolatedHomeEnvironmentVariable(for: .claude))
    }

    /// System language resolution must not enumerate the SwiftPM bundle during startup.
    func testPreferredSupportedLanguageUsesKnownLocalePrefixes() {
        XCTAssertEqual(
            LocalizationManager.preferredSupportedLanguage(from: ["zh-Hans-TH", "en-US"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            LocalizationManager.preferredSupportedLanguage(from: ["fr-FR", "en-GB"]),
            "en"
        )
        XCTAssertEqual(
            LocalizationManager.preferredSupportedLanguage(from: ["fr-FR"]),
            "en"
        )
    }

    /// The hover switcher and account cards must present the same account title.
    func testAccountSwitcherTitleIncludesDisplayLabelAndPlan() {
        var account = Account(
            provider: .codex,
            label: "generated",
            customLabel: "user@example.com",
            email: "user@example.com",
            plan: .pro,
            accountID: "synthetic",
            credentialSnapshot: nil
        )
        account.usage = .empty

        XCTAssertEqual(
            AccountSwitcherPopover.title(for: account),
            "user@example.com (Pro)"
        )
    }

    /// Provider sections remain stable even when persisted accounts arrive out of order.
    @MainActor
    func testMenuProviderSectionsUseStableCompanyOrder() {
        let claude = Account(provider: .claude, label: "Claude", plan: .pro)
        let codex = Account(provider: .codex, label: "Codex", plan: .plus)

        XCTAssertEqual(
            MenuContentView.visibleProviders(in: [claude, codex]),
            [.codex, .claude]
        )
        XCTAssertEqual(MenuContentView.visibleProviders(in: [claude]), [.claude])
        XCTAssertTrue(MenuContentView.visibleProviders(in: []).isEmpty)
    }

    /// Accumulated runtime uses compact localized units and omits empty day/hour groups.
    @MainActor
    func testRuntimeTextUsesCompactLocalizedUnits() {
        let localization = LocalizationManager()
        let originalLanguage = localization.language
        defer { localization.language = originalLanguage }

        localization.language = .english
        XCTAssertEqual(MenuContentView.runtimeText(45, loc: localization), "0m")
        XCTAssertEqual(MenuContentView.runtimeText(7_500, loc: localization), "2h 5m")
        XCTAssertEqual(MenuContentView.runtimeText(183_840, loc: localization), "2d 3h 4m")

        localization.language = .chinese
        XCTAssertEqual(MenuContentView.runtimeText(7_500, loc: localization), "2小时 5分")
    }

    /// Reset details include only available, unexpired credits in expiry order.
    func testResetCreditDetailsFilterAndSortAvailableRows() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter.parse("2026-08-04T12:00:00Z"))
        let payload: [String: Any] = [
            "credits": [
                [
                    "id": "later", "status": "available",
                    "expires_at": "2026-08-12T12:00:00Z",
                ],
                [
                    "id": "redeemed", "status": "redeemed",
                    "expires_at": "2026-08-06T12:00:00Z",
                ],
                [
                    "id": "expired", "status": "available",
                    "expires_at": "2026-08-03T12:00:00Z",
                ],
                [
                    "id": "earlier", "status": "available",
                    "expires_at": "2026-08-08T12:00:00Z", "title": "Free reset",
                ],
                ["id": "no-expiry", "status": "available"],
            ]
        ]

        let credits = try XCTUnwrap(UsageService.parseResetCreditDetails(payload, now: now))

        XCTAssertEqual(credits.map(\.id), ["earlier", "later", "no-expiry"])
        XCTAssertEqual(credits.first?.title, "Free reset")
    }

    /// Missing/invalid reset-credit values are not equivalent to a real zero.
    func testResetCreditCountPreservesUnknownAndClampsNegativeValues() {
        XCTAssertEqual(UsageService.parseResetCredits(["available_count": 2]), 2)
        XCTAssertEqual(UsageService.parseResetCredits(["available_count": -4]), 0)
        XCTAssertEqual(
            UsageService.parseResetCredits(["available_count": Double.greatestFiniteMagnitude]),
            Int.max)
        XCTAssertNil(UsageService.parseResetCredits([:]))
        XCTAssertNil(UsageService.parseResetCredits(["available_count": true]))
    }

    /// Reset redemption accepts the provider/app-server outcome spellings and
    /// fails closed when a successful-looking body omits a recognized code.
    func testResetOutcomeParserRecognizesOnlyExplicitOutcomes() {
        XCTAssertEqual(UsageService.parseResetOutcome(["code": "reset"]), .reset)
        XCTAssertEqual(
            UsageService.parseResetOutcome(["outcome": "alreadyRedeemed"]),
            .alreadyRedeemed
        )
        XCTAssertEqual(
            UsageService.parseResetOutcome(["result": ["status": "nothing_to_reset"]]),
            .nothingToReset
        )
        XCTAssertEqual(UsageService.parseResetOutcome(["code": "no_credit"]), .noCredit)
        XCTAssertEqual(
            UsageService.parseResetOutcome(["code": "reset_wrong_provider"]),
            .wrongProvider
        )
        XCTAssertNil(UsageService.parseResetOutcome(["success": true]))
        XCTAssertNil(UsageService.parseResetOutcome(["code": "unexpected_success"]))
    }

    /// Every logical redemption carries one UUID idempotency key and includes a
    /// concrete credit only when the provider returned a non-empty identifier.
    func testResetRequestPayloadIsIdempotentAndOmitsBlankCreditID() {
        let idempotencyKey = UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!

        XCTAssertEqual(
            UsageService.resetRequestPayload(
                creditID: "credit-1",
                idempotencyKey: idempotencyKey
            ),
            [
                "redeem_request_id": "123e4567-e89b-12d3-a456-426614174000",
                "credit_id": "credit-1",
            ]
        )
        XCTAssertEqual(
            UsageService.resetRequestPayload(
                creditID: "  ",
                idempotencyKey: idempotencyKey
            ),
            ["redeem_request_id": "123e4567-e89b-12d3-a456-426614174000"]
        )
    }

    /// Cancel, Escape-equivalent, and aborted modal responses must never reach
    /// the irreversible reset service; only the first destructive button may proceed.
    @MainActor
    func testResetConfirmationFailsClosedForCancelResponses() {
        XCTAssertTrue(
            ResetCreditAlertPresenter.isConfirmed(.alertFirstButtonReturn)
        )
        XCTAssertFalse(
            ResetCreditAlertPresenter.isConfirmed(.alertSecondButtonReturn)
        )
        XCTAssertFalse(ResetCreditAlertPresenter.isConfirmed(.abort))
        XCTAssertFalse(ResetCreditAlertPresenter.isConfirmed(.stop))
    }

    /// Credential helpers must not leave generated token files group/world-readable.
    func testSecureFileWriterUsesOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("credential.json")
        try SecureFileWriter.write(Data("secret".utf8), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    /// Settings mutations persist a custom label and never remove a live account.
    @MainActor
    func testAccountSettingsRenameAndRemovalRules() {
        let manager = AccountsManager(ephemeral: true)
        manager.installMockData()

        let activeAccount = manager.accounts[0]
        let inactiveAccount = manager.accounts[1]
        let remainingAccount = manager.accounts[2]

        XCTAssertTrue(manager.rename(inactiveAccount, to: "  Secondary  "))
        XCTAssertEqual(manager.accounts[1].displayLabel, "Secondary")
        XCTAssertFalse(manager.rename(inactiveAccount, to: "   "))

        XCTAssertFalse(manager.remove(activeAccount))
        XCTAssertEqual(manager.accounts.count, 3)
        XCTAssertTrue(manager.remove(inactiveAccount))
        XCTAssertEqual(manager.accounts.map(\.id), [activeAccount.id, remainingAccount.id])
    }
}
