import Foundation
import Observation

/// Central store: owns the list of accounts, which one is active, and
/// coordinates credential snapshots + usage refresh. Backs the whole UI.
@MainActor
@Observable
final class AccountsManager {
    enum ImportResult {
        case added(Account)
        case updated(Account)

        var account: Account {
            switch self {
            case .added(let account), .updated(let account): return account
            }
        }
    }

    enum ImportError: Error, LocalizedError {
        case unreadableFile
        case invalidCredential
        case missingAccountIdentity
        case snapshotWriteFailed
        case activationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile: return "The selected file could not be read."
            case .invalidCredential: return "The selected file is not a valid provider credential."
            case .missingAccountIdentity:
                return "The credential does not contain an account identity."
            case .snapshotWriteFailed: return "The credential could not be stored securely."
            case .activationFailed: return "The credential was saved but could not be activated."
            }
        }
    }

    static let shared = AccountsManager()

    private(set) var accounts: [Account] = []
    /// Codex and Claude have independent live credentials, so each provider can
    /// have one active account at the same time.
    private(set) var activeAccountIDs: [Provider: UUID] = [:]

    var isRefreshing = false
    private(set) var resettingAccountIDs: Set<UUID> = []
    private(set) var refreshErrors: [UUID: String] = [:]
    /// Credential generations the provider has already rejected, keyed by account.
    private var rejectedCredentials: [UUID: String] = [:]
    var lastError: String?

    /// Optional trial banner state (mirrors the reference app).
    var trialRemaining: TimeInterval? = nil

    private let persistenceURL: URL
    /// When true, never write to disk (used by the offscreen previewer).
    private let ephemeral: Bool
    /// Claude snapshot storage. Overridable so tests never touch real credentials.
    private let claudeStore: ClaudeCredentialStore
    /// Codex paths are injectable so import/recovery tests never touch real credentials.
    private let codexStore: CodexCredentialStore
    /// Usage transport, injected so refresh behavior is testable without network.
    private let fetchUsage: @Sendable (Account) async throws -> Usage

    init(
        ephemeral: Bool = false,
        claudeStore: ClaudeCredentialStore = .shared,
        codexStore: CodexCredentialStore = .shared,
        fetchUsage: @escaping @Sendable (Account) async throws -> Usage = {
            try await UsageService.fetch(for: $0)
        }
    ) {
        self.ephemeral = ephemeral
        self.claudeStore = claudeStore
        self.codexStore = codexStore
        self.fetchUsage = fetchUsage
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        persistenceURL = support.appendingPathComponent("accounts.json")
        if !ephemeral { load() }
    }

    /// Compatibility accessor used for the menu-bar icon and legacy snapshots.
    var activeAccountID: UUID? {
        activeAccountIDs[.codex] ?? activeAccountIDs[.claude]
    }

    /// Whether this account owns its provider's live CLI credential.
    func isActive(_ account: Account) -> Bool {
        activeAccountIDs[account.provider] == account.id
    }

    /// Most recent refresh failure for an account. Stale successful data is
    /// retained separately so a transient network error does not blank the UI.
    func refreshError(for account: Account) -> String? {
        refreshErrors[account.id]
    }

    /// Whether an irreversible reset-credit request is currently running.
    func isResetting(_ account: Account) -> Bool {
        resettingAccountIDs.contains(account.id)
    }

    /// Load synthetic preview accounts; optionally show Codex recovery text without disk or HTTP access.
    func installMockData(codexAuthError: Bool = false) {
        func date(_ day: Int) -> Date {
            var c = DateComponents()
            c.year = 2026
            c.month = 8
            c.day = day
            return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
        }
        var a = Account(
            provider: .codex, label: "tmtdeveloper1", email: nil,
            plan: .pro, accountID: "mock-1", credentialSnapshot: nil)
        a.usage = Usage(
            fiveHour: UsageWindow(usedFraction: 0.65, resetsAt: date(8)),
            sevenDay: UsageWindow(usedFraction: 0.93, resetsAt: date(8)),
            resetsAvailable: 0, fetchedAt: Date())
        var b = Account(
            provider: .codex, label: "jarrott999", email: nil,
            plan: .pro, accountID: "mock-2", credentialSnapshot: nil)
        b.usage = Usage(
            fiveHour: UsageWindow(usedFraction: nil, resetsAt: nil),
            sevenDay: UsageWindow(usedFraction: 0.19, resetsAt: date(9)),
            resetsAvailable: 1,
            fetchedAt: Date(),
            resetCredits: [
                ResetCredit(
                    id: "mock-reset-1",
                    title: "One free rate limit reset",
                    expiresAt: date(9)
                )
            ])
        var c = Account(
            provider: .claude, label: "Claude", email: nil,
            plan: .pro, accountID: "mock-3", credentialSnapshot: nil)
        c.usage = Usage(
            fiveHour: UsageWindow(usedFraction: 0.27, resetsAt: date(9)),
            sevenDay: UsageWindow(usedFraction: 0.03, resetsAt: date(10)),
            resetsAvailable: nil,
            fetchedAt: Date()
        )
        accounts = [a, b, c]
        if codexAuthError { record(CodexAuthError.loginRequired, for: a.id) }
        activeAccountIDs[.codex] = a.id
        activeAccountIDs[.claude] = c.id
        trialRemaining = 2 * 86_400 + 16 * 3_600 + 52 * 60
    }

    /// Load the persisted store into an ephemeral manager (used by the previewer).
    func loadForPreview() {
        guard let data = try? Data(contentsOf: persistenceURL),
            let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else { return }
        apply(snapshot)
        trialRemaining = 2 * 86_400 + 16 * 3_600 + 52 * 60
    }

    // MARK: Discovery — import whatever is currently logged in

    /// Discover the live credential for every provider and reconcile it with the store.
    ///
    /// This method has no parameters or return value. Credential reads and snapshot
    /// creation run off the main actor; reconciliation and JSON persistence run on
    /// the main actor. Codex is committed before the potentially slower Claude
    /// Keychain read, so Claude access cannot delay restoring the Codex checkmark.
    /// A missing provider credential clears only that provider's active marker.
    func discoverLiveAccounts() async {
        reconcileLiveAccount(await liveAccount(provider: .codex), provider: .codex)
        persist()
        reconcileLiveAccount(await liveAccount(provider: .claude), provider: .claude)
        persist()
    }

    /// Read one provider's live credential off the main actor.
    ///
    /// - Parameter provider: Provider whose live credential should be inspected.
    /// - Returns: The live login reconciled against managed storage, or `nil` when
    ///   that provider has no usable credential.
    /// - Side effects: Writes an owner-only snapshot of the live credential.
    private func liveAccount(provider: Provider) async -> Account? {
        let store = claudeStore
        let codexStore = self.codexStore
        return await Task.detached(priority: .utility) {
            switch provider {
            case .codex: return Self.buildCodexAccount(store: codexStore)
            case .claude: return Self.buildClaudeAccount(store: store)
            }
        }.value
    }

    /// Reconcile one provider result without changing another provider's selection.
    ///
    /// - Parameters:
    ///   - discovered: Valid live account, or `nil` when its credential is unavailable.
    ///   - provider: Provider whose active marker is being repaired.
    /// - Side effects: Updates only the in-memory account list and provider marker;
    ///   the caller controls persistence timing.
    private func reconcileLiveAccount(_ discovered: Account?, provider: Provider) {
        if let discovered {
            _ = reconcile(discovered, markActive: true)
        } else {
            activeAccountIDs.removeValue(forKey: provider)
        }
    }

    /// Import the provider credential that is currently live on this Mac.
    ///
    /// - Parameter provider: Codex or Claude credential source to inspect.
    /// - Returns: Added/updated account, or `nil` when no usable login is found.
    /// - Side effects: Creates an owner-only snapshot and marks the account active.
    func importCurrentAccount(provider: Provider) async -> ImportResult? {
        guard let discovered = await liveAccount(provider: provider) else { return nil }
        let result = reconcile(discovered, markActive: true)
        persist()
        return result
    }

    /// Import a provider credential JSON file without replacing the live CLI login.
    ///
    /// - Parameters:
    ///   - provider: Expected credential schema.
    ///   - url: User-selected local JSON file.
    /// - Returns: Added or updated managed account.
    /// - Throws: `ImportError` when validation or secure persistence fails.
    func importCredentialFile(provider: Provider, url: URL) async throws -> ImportResult {
        let data: Data = try await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else {
                throw ImportError.unreadableFile
            }
            return data
        }.value
        return try await importCredentialData(provider: provider, data: data)
    }

    /// Validate and snapshot credential bytes, optionally committing them as live.
    ///
    /// - Parameters:
    ///   - provider: Expected credential schema and destination store.
    ///   - data: Provider credential JSON; never logged or returned to the UI.
    ///   - activate: When true, replace the live provider credential only after
    ///     validation and owner-only snapshot persistence both succeed.
    /// - Returns: Added or updated managed account.
    /// - Throws: `ImportError` for invalid data, snapshot failure, cancellation,
    ///   or a failed atomic activation.
    /// - Side effects: Writes a managed snapshot and, when requested, the live
    ///   provider credential plus its persisted active marker.
    func importCredentialData(
        provider: Provider,
        data: Data,
        activate: Bool = false
    ) async throws -> ImportResult {
        try Task.checkCancellation()
        let claudeStore = self.claudeStore
        let codexStore = self.codexStore
        let discovered: Account = try await Task.detached(priority: .userInitiated) {
            switch provider {
            case .codex:
                guard let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
                    auth.tokens?.accessToken != nil
                else {
                    throw ImportError.invalidCredential
                }
                guard let accountID = auth.accountID else {
                    throw ImportError.missingAccountIdentity
                }
                guard
                    let snapshot = codexStore.snapshot(
                        data: data,
                        accountID: accountID
                    )
                else {
                    throw ImportError.snapshotWriteFailed
                }
                return Self.makeCodexAccount(auth: auth, snapshot: snapshot)
            case .claude:
                guard let auth = try? JSONDecoder().decode(ClaudeAuth.self, from: data),
                    auth.accessToken != nil
                else { throw ImportError.invalidCredential }
                guard let accountID = claudeStore.stableAccountID(for: auth) else {
                    throw ImportError.missingAccountIdentity
                }
                guard
                    let snapshot = claudeStore.snapshot(
                        data: data,
                        accountID: accountID
                    )
                else {
                    throw ImportError.snapshotWriteFailed
                }
                return Self.makeClaudeAccount(auth: auth, accountID: accountID, snapshot: snapshot)
            }
        }.value

        try Task.checkCancellation()
        let result = reconcile(discovered, markActive: false)
        if activate, !commitLiveCredential(for: result.account) {
            persist()
            throw ImportError.activationFailed
        }
        persist()
        return result
    }

    /// Replace one provider's live credential from a validated managed snapshot.
    ///
    /// - Parameter account: Reconciled account whose snapshot is ready to commit.
    /// - Returns: Whether the provider store accepted the credential.
    /// - Side effects: Writes the provider's live credential and updates active state.
    ///   Failure leaves the previous active marker unchanged.
    private func commitLiveCredential(for account: Account) -> Bool {
        guard let snapshot = account.credentialSnapshot else {
            lastError = "This account has no usable credential snapshot"
            return false
        }
        let activated: Bool
        switch account.provider {
        case .codex: activated = codexStore.activate(snapshot: snapshot)
        case .claude: activated = claudeStore.activate(snapshot: snapshot)
        }
        guard activated else {
            lastError = "Failed to switch account"
            return false
        }
        activeAccountIDs[account.provider] = account.id
        lastError = nil
        return true
    }

    /// Capture the provider login that must be restored if a new OAuth flow fails.
    ///
    /// - Parameter provider: Provider about to start browser OAuth.
    /// - Returns: Freshly reconciled live account when available, otherwise the
    ///   account currently marked active for that provider.
    /// - Side effects: Securely snapshots the live credential and persists its
    ///   active marker before the external CLI is allowed to modify login state.
    func prepareBrowserLoginRollback(provider: Provider) async -> Account? {
        if let current = await importCurrentAccount(provider: provider) {
            return current.account
        }
        guard let activeID = activeAccountIDs[provider] else { return nil }
        return accounts.first { $0.id == activeID && $0.provider == provider }
    }

    /// Restore the credential and selection captured before a failed OAuth flow.
    ///
    /// - Parameter account: Account returned by `prepareBrowserLoginRollback`.
    /// - Returns: `true` when restored or when the user selected a different
    ///   account while OAuth was open; `false` when the saved snapshot is unusable.
    /// - Side effects: Rewrites only the provider's live credential and persists
    ///   the restored active marker. It never overwrites a newer explicit switch.
    @discardableResult
    func rollbackBrowserLogin(to account: Account) -> Bool {
        let currentActiveID = activeAccountIDs[account.provider]
        if let currentActiveID, currentActiveID != account.id { return true }
        guard let snapshot = account.credentialSnapshot else {
            lastError = "The previous account has no credential snapshot to restore."
            return false
        }

        let restored: Bool
        switch account.provider {
        case .codex: restored = codexStore.activate(snapshot: snapshot)
        case .claude: restored = claudeStore.activate(snapshot: snapshot)
        }
        guard restored else {
            lastError = "The previous account credential could not be restored."
            return false
        }

        activeAccountIDs[account.provider] = account.id
        lastError = nil
        persist()
        return true
    }

    /// Read and snapshot the live Codex login off the main actor; injected paths isolate tests.
    nonisolated static func buildCodexAccount(store: CodexCredentialStore = .shared) -> Account? {
        guard let auth = store.currentAuth(),
            auth.tokens?.accessToken != nil,
            let accountID = auth.accountID
        else { return nil }
        let snap = store.snapshotCurrent(accountID: accountID)
        return makeCodexAccount(auth: auth, snapshot: snap)
    }

    /// Convert validated Codex credential metadata into the persisted account model.
    nonisolated static func makeCodexAccount(auth: CodexAuth, snapshot: String?) -> Account {
        Account(
            provider: .codex,
            label: preferredCodexLabel(email: auth.email, name: auth.name),
            email: auth.email,
            plan: PlanTier.parse(auth.planType),
            accountID: auth.accountID,
            credentialSnapshot: snapshot
        )
    }

    /// Resolve the reference-compatible Codex label from identity claims.
    ///
    /// - Parameters:
    ///   - email: ChatGPT email claim; its local part is preferred.
    ///   - name: Profile name used only when the email is unavailable.
    /// - Returns: Stable display label without exposing the full email address.
    nonisolated static func preferredCodexLabel(email: String?, name: String?) -> String {
        email?.components(separatedBy: "@").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? name?.components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Codex"
    }

    nonisolated static func buildClaudeAccount(
        store: ClaudeCredentialStore = .shared
    ) -> Account? {
        guard let live = store.resolveLiveAccount() else { return nil }
        return makeClaudeAccount(
            auth: live.auth, accountID: live.accountID, snapshot: live.snapshot)
    }

    /// Convert validated Claude credential metadata into the persisted account model.
    /// Claude's credential carries no identity of its own, so the label stays generic
    /// until Claude Code's recorded account resolves one.
    nonisolated static func makeClaudeAccount(
        auth: ClaudeAuth,
        accountID: String,
        snapshot: String?
    ) -> Account {
        Account(
            provider: .claude,
            label: auth.accountIdentity?.label ?? Provider.claude.displayName,
            email: auth.accountIdentity?.email,
            plan: PlanTier.parse(auth.planType),
            accountID: accountID,
            credentialSnapshot: snapshot
        )
    }

    /// Merge a discovered/imported account while retaining its model identity and usage.
    private func reconcile(_ discovered: Account, markActive: Bool) -> ImportResult {
        let existingIndex = accounts.firstIndex {
            if $0.provider == discovered.provider && $0.accountID == discovered.accountID {
                return true
            }
            guard discovered.provider == .claude else { return false }
            return claudeStore.snapshotsContainSameAccount(
                $0.credentialSnapshot,
                discovered.credentialSnapshot
            )
        }

        if let existingIndex {
            // Discovery falls back to a generic label when a provider stops reporting
            // identity; that must not erase a label an earlier resolution produced.
            let generic = discovered.provider.displayName
            if discovered.label != generic || accounts[existingIndex].label == generic {
                accounts[existingIndex].label = discovered.label
            }
            accounts[existingIndex].email = discovered.email ?? accounts[existingIndex].email
            if discovered.plan != .unknown {
                accounts[existingIndex].plan = discovered.plan
            }
            accounts[existingIndex].accountID = discovered.accountID
            accounts[existingIndex].credentialSnapshot =
                discovered.credentialSnapshot ?? accounts[existingIndex].credentialSnapshot
            if markActive {
                activeAccountIDs[discovered.provider] = accounts[existingIndex].id
            }
            return .updated(accounts[existingIndex])
        }

        accounts.append(discovered)
        if markActive { activeAccountIDs[discovered.provider] = discovered.id }
        return .added(discovered)
    }

    // MARK: Switching

    /// Activate one managed account for its provider.
    ///
    /// - Parameter account: Account whose credential snapshot should become live.
    /// - Side effects: Backs up the live credential, replaces it, and persists active state.
    /// - Failure: Leaves active state unchanged and stores a user-visible `lastError`.
    func activate(_ account: Account) async {
        guard !isActive(account) else { return }
        await captureLiveCredential(provider: account.provider)
        guard let target = accounts.first(where: { $0.id == account.id }) else { return }
        if commitLiveCredential(for: target) {
            persist()
        }
    }

    /// Snapshot the provider credential that is live right now, before it is replaced.
    ///
    /// - Parameter provider: Provider whose live credential is about to change.
    /// - Side effects: Reconciles the live login without changing which account is
    ///   active, writing its current generation to a managed snapshot.
    ///
    /// Provider CLIs rotate their tokens outside the switcher, so the generation
    /// captured at launch is routinely stale by the time the user switches. Writing
    /// over it without this capture would leave the account losing the slot holding
    /// a superseded credential it can never present again. A live login the switcher
    /// does not recognize is kept as its own account rather than silently discarded.
    private func captureLiveCredential(provider: Provider) async {
        guard let live = await liveAccount(provider: provider) else { return }
        _ = reconcile(live, markActive: false)
    }

    /// Rename an account without letting provider discovery overwrite the override.
    @discardableResult
    func rename(_ account: Account, to proposedLabel: String) -> Bool {
        let label = proposedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64,
            let index = accounts.firstIndex(where: { $0.id == account.id })
        else { return false }
        accounts[index].customLabel = label == accounts[index].label ? nil : label
        persist()
        return true
    }

    /// Remove one inactive account and its managed snapshot.
    /// Active credentials are protected so the account cannot immediately reappear.
    @discardableResult
    func remove(_ account: Account) -> Bool {
        guard !isActive(account) else {
            lastError = "Switch to another account before removing this active account."
            return false
        }
        if let snapshot = account.credentialSnapshot {
            let removed: Bool
            switch account.provider {
            case .codex: removed = codexStore.removeSnapshot(snapshot)
            case .claude: removed = claudeStore.removeSnapshot(snapshot)
            }
            guard removed else {
                lastError = "The account snapshot could not be removed."
                return false
            }
        }
        accounts.removeAll { $0.id == account.id }
        refreshErrors.removeValue(forKey: account.id)
        lastError = nil
        persist()
        return true
    }

    // MARK: Usage refresh

    private var autoRefreshTask: Task<Void, Never>?

    /// Refresh usage on a timer (every 5 minutes) until the app quits.
    func startAutoRefresh(interval: TimeInterval = 300) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refreshAll()
            }
        }
    }

    /// Refresh all account usage concurrently while retaining last-known-good data.
    ///
    /// - Parameter retryingRejectedLogins: Clears the latch that holds back accounts
    ///   whose stored credential the provider already rejected. User-initiated
    ///   refreshes pass `true`; the five-minute timer does not.
    /// - Side effects: Per-account failures are recorded in `refreshErrors`; successful
    ///   snapshots are persisted atomically. Overlapping refresh attempts are coalesced.
    ///   Provider renewal failures are localized on the main actor without including
    ///   provider response bodies or credentials.
    func refreshAll(retryingRejectedLogins: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if retryingRejectedLogins { rejectedCredentials.removeAll() }

        await withTaskGroup(of: (UUID, Usage?, Error?).self) { group in
            let fetch = fetchUsage
            for account in accounts where !isRefreshBlocked(account) {
                group.addTask {
                    do {
                        return (account.id, try await fetch(account), nil)
                    } catch {
                        return (account.id, nil, error)
                    }
                }
            }
            for await (id, usage, error) in group {
                if let usage, let index = accounts.firstIndex(where: { $0.id == id }) {
                    accounts[index].usage = usage
                    refreshErrors.removeValue(forKey: id)
                    rejectedCredentials.removeValue(forKey: id)
                } else if let error {
                    record(error, for: id)
                }
            }
        }
        lastError = refreshErrors.isEmpty ? nil : "Some usage data could not be refreshed"
        persist()
    }

    /// Store one localized failure and latch a credential the provider rejected.
    private func record(_ error: Error, for id: UUID) {
        if let authError = error as? CodexAuthError {
            refreshErrors[id] = authError.displayMessage
        } else if let authError = error as? ClaudeAuthError {
            refreshErrors[id] = authError.displayMessage
            if case .loginRequired = authError,
                let account = accounts.first(where: { $0.id == id })
            {
                rejectedCredentials[id] = credentialGeneration(of: account)
            }
        } else {
            refreshErrors[id] = error.localizedDescription
        }
    }

    /// Whether this account's stored credential was already rejected by the provider.
    ///
    /// Claude rotates refresh tokens and a rejected one stays rejected until the
    /// credential changes. Presenting it again every five minutes replays a consumed
    /// token, which providers treat as token reuse and may answer by revoking the
    /// whole token family — including the login Claude Code is still using. The latch
    /// releases itself as soon as the snapshot holds a different generation.
    private func isRefreshBlocked(_ account: Account) -> Bool {
        guard let rejected = rejectedCredentials[account.id] else { return false }
        guard credentialGeneration(of: account) == rejected else {
            rejectedCredentials.removeValue(forKey: account.id)
            return false
        }
        return true
    }

    /// Identify the credential generation an account currently holds.
    /// Unreadable storage collapses to one sentinel rather than a missing value,
    /// so a rejection can never be latched under a key that silently disappears.
    private func credentialGeneration(of account: Account) -> String {
        claudeStore.snapshotFingerprint(account.credentialSnapshot) ?? "unavailable"
    }

    /// Consume one confirmed Codex reset credit and reconcile the provider snapshot.
    ///
    /// - Parameters:
    ///   - account: Managed account selected by the reset row.
    ///   - creditID: Optional earliest-expiring credit identifier from the last refresh.
    /// - Returns: Explicit provider outcome; callers decide which localized message to show.
    /// - Throws: Credential, transport, HTTP, or decoding failures from `UsageService`.
    /// - Side effects: May irreversibly consume one credit. Duplicate taps are coalesced;
    ///   after any recognized outcome, fresh usage is fetched and persisted best-effort.
    func consumeResetCredit(
        for account: Account,
        creditID: String?
    ) async throws -> UsageService.ResetOutcome {
        guard !resettingAccountIDs.contains(account.id) else {
            throw UsageService.FetchError.network("A reset request is already in progress")
        }
        guard let storedAccount = accounts.first(where: { $0.id == account.id }) else {
            throw UsageService.FetchError.noCredentials
        }

        resettingAccountIDs.insert(account.id)
        defer { resettingAccountIDs.remove(account.id) }

        let outcome = try await UsageService.consumeResetCredit(
            for: storedAccount,
            creditID: creditID
        )

        do {
            let usage = try await UsageService.fetch(for: storedAccount)
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].usage = usage
                refreshErrors.removeValue(forKey: account.id)
            }
        } catch {
            // Redemption may already have succeeded. Preserve that outcome and the
            // last-known-good snapshot while surfacing only the follow-up refresh error.
            record(error, for: account.id)
        }
        lastError = refreshErrors.isEmpty ? nil : "Some usage data could not be refreshed"
        persist()
        return outcome
    }

    // MARK: Persistence

    private func persist() {
        guard !ephemeral else { return }
        let snapshot = PersistedSnapshot(
            accounts: accounts,
            activeID: activeAccountID,
            activeIDs: Dictionary(
                uniqueKeysWithValues: activeAccountIDs.map { ($0.key.rawValue, $0.value) }
            )
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("AISwitcher: persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
            let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else {
            return
        }
        apply(snapshot)
    }

    /// Apply the current multi-provider persistence schema, while migrating the
    /// single `activeID` stored by previous versions.
    private func apply(_ snapshot: PersistedSnapshot) {
        accounts = snapshot.accounts
        activeAccountIDs = Dictionary(
            uniqueKeysWithValues: (snapshot.activeIDs ?? [:]).compactMap { key, value in
                guard let provider = Provider(rawValue: key),
                    accounts.contains(where: { $0.id == value && $0.provider == provider })
                else { return nil }
                return (provider, value)
            }
        )
        if activeAccountIDs.isEmpty,
            let legacyID = snapshot.activeID,
            let legacyAccount = accounts.first(where: { $0.id == legacyID })
        {
            activeAccountIDs[legacyAccount.provider] = legacyID
        }
        repairStoredCodexMetadata()
    }

    /// Rebuild automatically generated Codex labels and plan metadata from every
    /// saved snapshot. This repairs inactive accounts without requiring a switch.
    private func repairStoredCodexMetadata() {
        for index in accounts.indices where accounts[index].provider == .codex {
            guard let snapshot = accounts[index].credentialSnapshot,
                let auth = codexStore.loadSnapshot(snapshot)
            else { continue }
            accounts[index].label = Self.preferredCodexLabel(email: auth.email, name: auth.name)
            accounts[index].email = auth.email ?? accounts[index].email
            let plan = PlanTier.parse(auth.planType)
            if plan != .unknown { accounts[index].plan = plan }
        }
    }

}

/// Version-tolerant persisted state. `activeID` remains readable for migration;
/// new builds store the provider-keyed `activeIDs` map.
private struct PersistedSnapshot: Codable {
    var accounts: [Account]
    var activeID: UUID?
    var activeIDs: [String: UUID]?
}
