import AppKit
import SwiftUI

/// Account management, drag-and-drop ordering, and language preferences window.
struct SettingsView: View {
    @Bindable var accounts: AccountsManager
    @Bindable var loc: LocalizationManager

    @Environment(\.openWindow) private var openWindow
    @State private var pendingRemoval: Account?
    @State private var targetedProviderSection: Provider?

    var body: some View {
        let providers = accounts.visibleProviders
        VStack(alignment: .leading, spacing: 18) {
            Text(loc.string("settings.title"))
                .font(.title2.weight(.semibold))

            HStack {
                Text(loc.string("settings.language"))
                Spacer()
                Picker("", selection: $loc.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(loc.string("settings.accounts"))
                        .font(.headline)
                    Spacer()
                    if accounts.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(loc.string("menu.refresh")) {
                        Task { await accounts.refreshAll(retryingRejectedLogins: true) }
                    }
                    .disabled(accounts.isRefreshing || accounts.accounts.isEmpty)
                    Button(loc.string("menu.add_account")) {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: AppWindowID.addAccount)
                    }
                }

                if canReorderAnything(providers: providers) {
                    Text(loc.string("reorder.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if accounts.accounts.isEmpty {
                ContentUnavailableView(
                    loc.string("settings.no_accounts_title"),
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(loc.string("settings.no_accounts"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(providers.enumerated()), id: \.element.id) {
                        sectionIndex, provider in
                        let providerAccounts = accounts.accounts(for: provider)
                        Section {
                            ForEach(providerAccounts) { account in
                                AccountSettingsRow(
                                    account: account,
                                    isActive: accounts.isActive(account),
                                    canReorder: providerAccounts.count > 1,
                                    loc: loc,
                                    onRename: { accounts.rename(account, to: $0) },
                                    onActivate: { Task { await accounts.activate(account) } },
                                    onRemove: { pendingRemoval = account }
                                )
                            }
                            .onMove { source, destination in
                                accounts.moveAccounts(
                                    in: provider,
                                    fromOffsets: source,
                                    toOffset: destination
                                )
                            }
                        } header: {
                            ProviderSettingsSectionHeader(
                                provider: provider,
                                sectionIndex: sectionIndex,
                                totalSections: providers.count,
                                isDropTargeted: targetedProviderSection == provider,
                                loc: loc,
                                onMoveUp: {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        accounts.moveProvider(
                                            provider,
                                            toVisibleIndex: max(0, sectionIndex - 1)
                                        )
                                    }
                                },
                                onMoveDown: {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        accounts.moveProvider(
                                            provider,
                                            toVisibleIndex: min(providers.count, sectionIndex + 2)
                                        )
                                    }
                                },
                                onDropProvider: { dropped in
                                    handleProviderDrop(
                                        dropped,
                                        onto: provider,
                                        providers: providers
                                    )
                                },
                                onDropTargetedChanged: { targeted in
                                    targetedProviderSection = targeted ? provider : nil
                                }
                            )
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            if let error = accounts.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 580, height: 460)
        .environment(\.locale, loc.locale)
        .confirmationDialog(
            loc.string("settings.remove_confirm_title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let account = pendingRemoval {
                Button(loc.string("settings.remove"), role: .destructive) {
                    _ = accounts.remove(account)
                    pendingRemoval = nil
                }
            }
            Button(loc.string("settings.cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            if let account = pendingRemoval {
                Text(
                    String(
                        format: loc.string("settings.remove_confirm_message"),
                        account.displayLabel
                    )
                )
            }
        }
    }

    private func canReorderAnything(providers: [Provider]) -> Bool {
        providers.count > 1
            || providers.contains { accounts.accounts(for: $0).count > 1 }
    }

    private func handleProviderDrop(
        _ dropped: Provider,
        onto target: Provider,
        providers: [Provider]
    ) -> Bool {
        guard let sourceIndex = providers.firstIndex(of: dropped),
            let targetIndex = providers.firstIndex(of: target),
            sourceIndex != targetIndex
        else { return false }
        let insertionIndex = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        withAnimation(.snappy(duration: 0.2)) {
            accounts.moveProvider(dropped, toVisibleIndex: insertionIndex)
        }
        return true
    }
}

/// Draggable provider section header in Account Settings with keyboard-accessible move buttons.
private struct ProviderSettingsSectionHeader: View {
    let provider: Provider
    let sectionIndex: Int
    let totalSections: Int
    let isDropTargeted: Bool
    let loc: LocalizationManager
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDropProvider: (Provider) -> Bool
    let onDropTargetedChanged: (Bool) -> Void

    private var canReorder: Bool { totalSections > 1 }

    var body: some View {
        let header = HStack(spacing: 8) {
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            ProviderBrandMark(provider: provider, size: 16)

            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(provider.companyDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if canReorder {
                HStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(sectionIndex == 0)
                    .help(loc.string("reorder.move_up"))
                    .accessibilityLabel(loc.string("reorder.move_up"))

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(sectionIndex >= totalSections - 1)
                    .help(loc.string("reorder.move_down"))
                    .accessibilityLabel(loc.string("reorder.move_down"))
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(provider.menuAccentColor.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(provider.menuAccentColor.opacity(0.65), lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())

        if canReorder {
            header
                .help(loc.string("reorder.section_help"))
                .draggable(provider.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let dropped = Provider(rawValue: raw) else {
                        return false
                    }
                    return onDropProvider(dropped)
                } isTargeted: { targeted in
                    onDropTargetedChanged(targeted)
                }
        } else {
            header
        }
    }
}

/// Editable account row that commits a custom label on Return or focus loss.
private struct AccountSettingsRow: View {
    let account: Account
    let isActive: Bool
    let canReorder: Bool
    let loc: LocalizationManager
    let onRename: (String) -> Bool
    let onActivate: () -> Void
    let onRemove: () -> Void

    @State private var draftLabel: String
    @FocusState private var labelFocused: Bool

    init(
        account: Account,
        isActive: Bool,
        canReorder: Bool,
        loc: LocalizationManager,
        onRename: @escaping (String) -> Bool,
        onActivate: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.isActive = isActive
        self.canReorder = canReorder
        self.loc = loc
        self.onRename = onRename
        self.onActivate = onActivate
        self.onRemove = onRemove
        _draftLabel = State(initialValue: account.displayLabel)
    }

    var body: some View {
        HStack(spacing: 10) {
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help(loc.string("reorder.account_help"))
                    .accessibilityHidden(true)
            }

            ProviderBrandMark(provider: account.provider, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                TextField(loc.string("settings.account_name"), text: $draftLabel)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($labelFocused)
                    .onSubmit { commitLabel() }
                    .onChange(of: labelFocused) { _, focused in
                        if !focused { commitLabel() }
                    }
                HStack(spacing: 6) {
                    Text(account.provider.displayName)
                    Text("•")
                    Text(account.plan.displayName)
                    if let email = account.email {
                        Text("•")
                        Text(email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isActive {
                Label(loc.string("card.active"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(loc.string("settings.activate"), action: onActivate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(
                isActive
                    ? loc.string("settings.remove_active_help")
                    : loc.string("settings.remove")
            )
        }
        .padding(.vertical, 5)
        .onChange(of: account.displayLabel) { _, newLabel in
            if !labelFocused { draftLabel = newLabel }
        }
    }

    /// Validate and persist the draft, restoring the stored value on failure.
    private func commitLabel() {
        if !onRename(draftLabel) {
            draftLabel = account.displayLabel
        }
    }
}
