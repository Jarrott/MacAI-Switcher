import AppKit
import SwiftUI

/// Compact menu-bar dropdown containing account usage and working app actions.
/// The fixed metrics intentionally follow native macOS menu density.
struct MenuContentView: View {
    @Bindable var accounts: AccountsManager
    var loc: LocalizationManager
    var onQuit: () -> Void
    /// When true, use a solid dark fill instead of the live blur (offscreen render).
    var solidBackground: Bool = false

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showAccountSwitcher = false
    @State private var settingsRowHovering = false
    @State private var accountSwitcherHovering = false
    @State private var accountSwitcherDismissTask: Task<Void, Never>?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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

            // Account cards, grouped into visually distinct provider sections.
            if accounts.accounts.isEmpty {
                Text(loc.string("menu.no_accounts"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.visibleProviders(in: accounts.accounts)) { provider in
                        let providerAccounts = accounts.accounts.filter {
                            $0.provider == provider
                        }
                        ProviderSectionView(provider: provider) {
                            ForEach(Array(providerAccounts.enumerated()), id: \.element.id) {
                                idx, account in
                                AccountCardView(
                                    account: account,
                                    isActive: accounts.isActive(account),
                                    isRefreshing: accounts.isRefreshing
                                        && account.usage.fetchedAt == nil,
                                    isResetting: accounts.isResetting(account),
                                    errorMessage: accounts.refreshError(for: account),
                                    locale: loc.locale,
                                    onSelect: { Task { await accounts.activate(account) } },
                                    onConsumeReset: { creditID in
                                        try await accounts.consumeResetCredit(
                                            for: account,
                                            creditID: creditID
                                        )
                                    }
                                )
                                .padding(.horizontal, 6)

                                if idx < providerAccounts.count - 1 {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.10))
                                        .frame(height: 0.75)
                                        .padding(.leading, 39)
                                        .padding(.trailing, 9)
                                }
                            }
                        }
                    }
                }
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
        }
        .onReceive(
            NotificationCenter.default.publisher(for: MenuBarPanelController.didCloseNotification)
        ) { _ in
            dismissAccountSwitcher()
        }
        .onDisappear(perform: dismissAccountSwitcher)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    /// Return providers that have accounts in a stable OpenAI-then-Anthropic order.
    ///
    /// - Parameter accounts: Managed accounts in any persisted or discovery order.
    /// - Returns: Only represented providers, ordered by `Provider.allCases`.
    nonisolated static func visibleProviders(in accounts: [Account]) -> [Provider] {
        Provider.allCases.filter { provider in
            accounts.contains { $0.provider == provider }
        }
    }

    /// Activate the menu-bar agent and open a dedicated SwiftUI utility window.
    private func presentWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    /// Track Account Settings hover and open its account switcher immediately.
    ///
    /// - Parameter isHovering: Whether the pointer is inside the action row.
    /// - Side effects: Cancels pending dismissal and updates the attached popover.
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
    ///
    /// - Parameter isHovering: Whether the pointer is inside the account popover.
    /// - Side effects: Cancels or schedules the short native-submenu-style delay.
    private func updateAccountSwitcherHover(_ isHovering: Bool) {
        accountSwitcherHovering = isHovering
        if isHovering {
            accountSwitcherDismissTask?.cancel()
        } else {
            scheduleAccountSwitcherDismissal()
        }
    }

    /// Delay dismissal long enough for the pointer to cross the popover gap.
    ///
    /// The delay has no parameters or return value. A newer hover event cancels
    /// the task, so stale events cannot close a submenu currently in use.
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
    ///
    /// - Parameter account: Managed account selected by the user.
    /// - Side effects: Atomically replaces that provider's live credential when
    ///   needed, then dismisses the account switcher.
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
    ///
    /// This method has no parameters or return value. It cancels delayed work and
    /// clears both hover regions without attempting to present or dismiss UI.
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
    ///
    /// - Parameters:
    ///   - interval: Nonnegative accumulated running time in seconds.
    ///   - loc: Active localization resolver.
    /// - Returns: A compact localized duration such as `1d 2h 3m` or `2小时 3分`.
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
