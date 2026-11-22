import AppKit
import SwiftUI

/// Compact menu-bar dropdown containing account usage, drag reordering, and app actions.
/// The fixed metrics intentionally follow native macOS menu density.
struct MenuContentView: View {
    @Bindable var accounts: AccountsManager
    var loc: LocalizationManager
    var onQuit: () -> Void
    /// When true, use a solid dark fill instead of the live blur (offscreen render).
    var solidBackground: Bool = false

    private nonisolated static let reorderCoordinateSpace = "menu-accounts-space"

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showAccountSwitcher = false
    @State private var settingsRowHovering = false
    @State private var accountSwitcherHovering = false
    @State private var accountSwitcherDismissTask: Task<Void, Never>?

    // Drag-reordering state for provider sections.
    @State private var draggingProvider: Provider?
    @State private var providerDragOffset: CGFloat = 0
    @State private var providerDropIndex: Int?
    @State private var providerFrames: [Provider: CGRect] = [:]
    @State private var dragStartProviderFrames: [Provider: CGRect] = [:]

    // Drag-reordering state for accounts inside one provider section.
    @State private var draggingAccountID: UUID?
    @State private var draggingAccountProvider: Provider?
    @State private var accountDragOffset: CGFloat = 0
    @State private var accountDropIndex: Int?
    @State private var accountFrames: [UUID: CGRect] = [:]
    @State private var dragStartAccountFrames: [UUID: CGRect] = [:]

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let providers = accounts.visibleProviders
        VStack(alignment: .leading, spacing: 0) {

            // Persisted accumulated runtime and optional trial status.
            VStack(alignment: .leading, spacing: 3) {
                if let trial = accounts.trialRemaining {
                    Text(
                        String(
                            format: loc.string("trial.remaining"),
                            Self.trialText(trial, loc: loc))
                    )
                }

                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(
                        String(
                            format: loc.string("runtime.elapsed"),
                            Self.runtimeText(AppRuntime.elapsed, loc: loc)
                        )
                    )
                }
            }
            .font(.system(size: 13.25, weight: .regular))
            .foregroundStyle(.white.opacity(0.52))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 3)
            divider

            // Account cards, grouped into draggable provider sections.
            if accounts.accounts.isEmpty {
                Text(loc.string("menu.no_accounts"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(providers.enumerated()), id: \.element.id) {
                        providerIndex, provider in
                        providerSection(
                            provider: provider,
                            providerIndex: providerIndex,
                            providers: providers
                        )
                    }
                }
                .coordinateSpace(name: Self.reorderCoordinateSpace)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            divider

            // Action menu
            VStack(alignment: .leading, spacing: 0) {
                MenuActionRow(
                    title: loc.string("menu.add_account"),
                    shortcut: "⌘ N",
                    shortcutKey: "n",
                    action: { presentWindow(id: AppWindowID.addAccount) })
                MenuActionRow(
                    title: loc.string("menu.account_settings"),
                    showsChevron: true,
                    keepsHighlight: showAccountSwitcher
                        && (settingsRowHovering || accountSwitcherHovering),
                    onHoverChanged: updateSettingsRowHover,
                    action: openAccountSettings
                )
                .popover(
                    isPresented: $showAccountSwitcher,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .trailing
                ) {
                    AccountSwitcherPopover(
                        accounts: accounts,
                        loc: loc,
                        solidBackground: solidBackground,
                        onSelect: selectAccountFromSwitcher,
                        onOpenSettings: openAccountSettings
                    )
                    .onHover(perform: updateAccountSwitcherHover)
                }
                MenuActionRow(
                    title: loc.string("menu.launch_at_login"),
                    shortcut: "⌘ L",
                    shortcutKey: "l"
                ) {
                    launchAtLogin = LaunchAtLogin.setEnabled(!launchAtLogin)
                }

                MenuActionRow(
                    title: accounts.isRefreshing
                        ? loc.string("menu.refreshing")
                        : loc.string("menu.refresh"),
                    shortcut: "⌘ R",
                    shortcutKey: "r",
                    isLoading: accounts.isRefreshing,
                    isEnabled: !accounts.isRefreshing
                ) {
                    Task { await accounts.refreshAll(retryingRejectedLogins: true) }
                }
                MenuActionRow(
                    title: loc.string("menu.quit"),
                    shortcut: "⌘ Q",
                    shortcutKey: "q",
                    action: onQuit)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .padding(.bottom, 4)
        .frame(width: MenuBarPanelController.panelWidth)
        .menuGlassPanel(
            solidBackground: solidBackground,
            cornerRadius: 14,
            castsShadow: !solidBackground
        )
        .onChange(of: showAccountSwitcher) { _, isPresented in
            if !isPresented { resetAccountSwitcherHoverState() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            dismissAccountSwitcher()
            resetDragState()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: MenuBarPanelController.didCloseNotification)
        ) { _ in
            dismissAccountSwitcher()
            resetDragState()
        }
        .onAppear {
            if !solidBackground {
                _ = accounts.syncAntigravityAccounts()
            }
        }
        .onDisappear {
            dismissAccountSwitcher()
            resetDragState()
        }
    }

    @ViewBuilder
    private func providerSection(
        provider: Provider,
        providerIndex: Int,
        providers: [Provider]
    ) -> some View {
        let providerAccounts = accounts.accounts(for: provider)
        let isDraggingThisSection = draggingProvider == provider
        let showTopIndicator = draggingProvider != nil && providerDropIndex == providerIndex
        let showBottomIndicator =
            draggingProvider != nil
            && providerIndex == providers.count - 1
            && providerDropIndex == providers.count

        ProviderSectionView(
            provider: provider,
            canReorder: providers.count > 1,
            isDragging: isDraggingThisSection,
            dragCoordinateSpace: Self.reorderCoordinateSpace,
            onDragChanged: { value in
                handleProviderDragChanged(provider: provider, value: value, providers: providers)
            },
            onDragEnded: handleProviderDragEnded
        ) {
            ForEach(Array(providerAccounts.enumerated()), id: \.element.id) { idx, account in
                accountCardRow(
                    account: account,
                    index: idx,
                    providerAccounts: providerAccounts
                )
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.reorderCoordinateSpace))
        } action: { frame in
            if draggingProvider == nil && draggingAccountID == nil {
                providerFrames[provider] = frame
            }
        }
        .offset(y: isDraggingThisSection ? providerDragOffset : 0)
        .zIndex(isDraggingThisSection || draggingAccountProvider == provider ? 20 : 0)
        .overlay(alignment: .top) {
            if showTopIndicator, let moving = draggingProvider {
                DropInsertionIndicator(color: moving.menuAccentColor)
                    .padding(.horizontal, 6)
                    .offset(y: -5)
            }
        }
        .overlay(alignment: .bottom) {
            if showBottomIndicator, let moving = draggingProvider {
                DropInsertionIndicator(color: moving.menuAccentColor)
                    .padding(.horizontal, 6)
                    .offset(y: 5)
            }
        }
    }

    @ViewBuilder
    private func accountCardRow(
        account: Account,
        index: Int,
        providerAccounts: [Account]
    ) -> some View {
        let isDraggingThisAccount = draggingAccountID == account.id
        let isTargetProvider = draggingAccountProvider == account.provider
        let showTopIndicator = isTargetProvider && accountDropIndex == index
        let showBottomIndicator =
            isTargetProvider
            && index == providerAccounts.count - 1
            && accountDropIndex == providerAccounts.count

        VStack(spacing: 0) {
            AccountCardView(
                account: account,
                isActive: accounts.isActive(account),
                isRefreshing: accounts.isRefreshing && account.usage.fetchedAt == nil,
                isResetting: accounts.isResetting(account),
                errorMessage: accounts.refreshError(for: account),
                locale: loc.locale,
                canReorder: providerAccounts.count > 1,
                isDragging: isDraggingThisAccount,
                dragCoordinateSpace: Self.reorderCoordinateSpace,
                onDragChanged: { value in
                    handleAccountDragChanged(
                        account: account,
                        value: value,
                        providerAccounts: providerAccounts
                    )
                },
                onDragEnded: handleAccountDragEnded,
                onSelect: { Task { await accounts.activate(account) } },
                onConsumeReset: { creditID in
                    try await accounts.consumeResetCredit(
                        for: account,
                        creditID: creditID
                    )
                }
            )
            .padding(.horizontal, 6)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.reorderCoordinateSpace))
            } action: { frame in
                if draggingProvider == nil && draggingAccountID == nil {
                    accountFrames[account.id] = frame
                }
            }
            .offset(y: isDraggingThisAccount ? accountDragOffset : 0)
            .zIndex(isDraggingThisAccount ? 30 : 0)
            .overlay(alignment: .top) {
                if showTopIndicator {
                    DropInsertionIndicator(color: account.provider.menuAccentColor)
                        .padding(.horizontal, 12)
                        .offset(y: -1)
                }
            }
            .overlay(alignment: .bottom) {
                if showBottomIndicator {
                    DropInsertionIndicator(color: account.provider.menuAccentColor)
                        .padding(.horizontal, 12)
                        .offset(y: 1)
                }
            }

            if index < providerAccounts.count - 1 {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 0.75)
                    .padding(.leading, 39)
                    .padding(.trailing, 9)
            }
        }
    }

    private func handleProviderDragChanged(
        provider: Provider,
        value: DragGesture.Value,
        providers: [Provider]
    ) {
        guard draggingAccountID == nil, providers.count > 1 else { return }
        if draggingProvider == nil {
            draggingProvider = provider
            dragStartProviderFrames = providerFrames
        }
        guard draggingProvider == provider else { return }
        providerDragOffset = value.translation.height
        let target = ReorderGeometry.targetIndex(
            forDragY: value.location.y,
            orderedIDs: providers,
            frames: dragStartProviderFrames
        )
        if let sourceIndex = providers.firstIndex(of: provider),
            ReorderGeometry.movesItem(from: sourceIndex, to: target)
        {
            providerDropIndex = target
        } else {
            providerDropIndex = nil
        }
    }

    private func handleProviderDragEnded() {
        let moving = draggingProvider
        let target = providerDropIndex
        resetDragState()
        if let moving, let target {
            withAnimation(.snappy(duration: 0.2)) {
                accounts.moveProvider(moving, toVisibleIndex: target)
            }
        }
    }

    private func handleAccountDragChanged(
        account: Account,
        value: DragGesture.Value,
        providerAccounts: [Account]
    ) {
        guard draggingProvider == nil, providerAccounts.count > 1 else { return }
        if draggingAccountID == nil {
            draggingAccountID = account.id
            draggingAccountProvider = account.provider
            dragStartAccountFrames = accountFrames
        }
        guard draggingAccountID == account.id else { return }
        accountDragOffset = value.translation.height
        let orderedIDs = providerAccounts.map(\.id)
        let target = ReorderGeometry.targetIndex(
            forDragY: value.location.y,
            orderedIDs: orderedIDs,
            frames: dragStartAccountFrames
        )
        if let sourceIndex = orderedIDs.firstIndex(of: account.id),
            ReorderGeometry.movesItem(from: sourceIndex, to: target)
        {
            accountDropIndex = target
        } else {
            accountDropIndex = nil
        }
    }

    private func handleAccountDragEnded() {
        let movingID = draggingAccountID
        let target = accountDropIndex
        resetDragState()
        if let movingID, let target {
            withAnimation(.snappy(duration: 0.2)) {
                accounts.moveAccount(movingID, toIndexInProvider: target)
            }
        }
    }

    private func resetDragState() {
        draggingProvider = nil
        providerDragOffset = 0
        providerDropIndex = nil
        dragStartProviderFrames = [:]
        draggingAccountID = nil
        draggingAccountProvider = nil
        accountDragOffset = 0
        accountDropIndex = nil
        dragStartAccountFrames = [:]
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    /// Return providers that have accounts in the requested order (defaulting to `Provider.allCases`).
    nonisolated static func visibleProviders(
        in accounts: [Account],
        order: [Provider] = Provider.allCases
    ) -> [Provider] {
        AccountsManager.visibleProviders(in: accounts, order: order)
    }

    /// Activate the menu-bar agent and open a dedicated SwiftUI utility window.
    private func presentWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    /// Track Account Settings hover and open its account switcher immediately.
    private func updateSettingsRowHover(_ isHovering: Bool) {
        settingsRowHovering = isHovering
        if isHovering {
            accountSwitcherDismissTask?.cancel()
            showAccountSwitcher = true
        } else {
            scheduleAccountSwitcherDismissal()
        }
    }

    /// Keep the submenu open while the pointer crosses into or remains inside it.
    private func updateAccountSwitcherHover(_ isHovering: Bool) {
        accountSwitcherHovering = isHovering
        if isHovering {
            accountSwitcherDismissTask?.cancel()
        } else {
            scheduleAccountSwitcherDismissal()
        }
    }

    /// Delay dismissal long enough for the pointer to cross the popover gap.
    private func scheduleAccountSwitcherDismissal() {
        accountSwitcherDismissTask?.cancel()
        accountSwitcherDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, !settingsRowHovering, !accountSwitcherHovering else {
                return
            }
            showAccountSwitcher = false
        }
    }

    /// Activate a submenu account and close the hover surface.
    private func selectAccountFromSwitcher(_ account: Account) {
        if !accounts.isActive(account) {
            Task { await accounts.activate(account) }
        }
        dismissAccountSwitcher()
    }

    /// Open full account management from the hover submenu.
    private func openAccountSettings() {
        dismissAccountSwitcher()
        presentWindow(id: AppWindowID.accountSettings)
    }

    /// Cancel hover bookkeeping and close the account switcher immediately.
    private func dismissAccountSwitcher() {
        resetAccountSwitcherHoverState()
        showAccountSwitcher = false
    }

    /// Clear stale hover state after native or application-driven focus loss.
    private func resetAccountSwitcherHoverState() {
        accountSwitcherDismissTask?.cancel()
        accountSwitcherDismissTask = nil
        settingsRowHovering = false
        accountSwitcherHovering = false
    }

    /// Format a trial duration as "2d 16h 52m" / "2天 16小时 52分".
    static func trialText(_ interval: TimeInterval, loc: LocalizationManager) -> String {
        let total = Int(max(0, interval))
        let d = total / 86_400
        let h = (total % 86_400) / 3_600
        let m = (total % 3_600) / 60
        return String(format: loc.string("trial.days_hours_minutes"), d, h, m)
    }

    /// Format accumulated runtime without seconds so the menu can update once per minute.
    static func runtimeText(_ interval: TimeInterval, loc: LocalizationManager) -> String {
        let totalMinutes = Int(max(0, interval)) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return String(
                format: loc.string("runtime.days_hours_minutes"),
                days,
                hours,
                minutes
            )
        }
        if hours > 0 {
            return String(format: loc.string("runtime.hours_minutes"), hours, minutes)
        }
        return String(format: loc.string("runtime.minutes"), minutes)
    }
}
