import AppKit
import SwiftUI

/// Account management and language preferences presented in a dedicated window.
struct SettingsView: View {
    @Bindable var accounts: AccountsManager
    @Bindable var loc: LocalizationManager

    @Environment(\.openWindow) private var openWindow
    @State private var pendingRemoval: Account?

    var body: some View {
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

            if accounts.accounts.isEmpty {
                ContentUnavailableView(
                    loc.string("settings.no_accounts_title"),
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(loc.string("settings.no_accounts"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(accounts.accounts) { account in
                        AccountSettingsRow(
                            account: account,
                            isActive: accounts.isActive(account),
                            loc: loc,
                            onRename: { accounts.rename(account, to: $0) },
                            onActivate: { Task { await accounts.activate(account) } },
                            onRemove: { pendingRemoval = account }
                        )
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 250)
            }

            if let error = accounts.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 580, height: 440)
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
}

/// Editable account row that commits a custom label on Return or focus loss.
private struct AccountSettingsRow: View {
    let account: Account
    let isActive: Bool
    let loc: LocalizationManager
    let onRename: (String) -> Bool
    let onActivate: () -> Void
    let onRemove: () -> Void

    @State private var draftLabel: String
    @FocusState private var labelFocused: Bool

    init(
        account: Account,
        isActive: Bool,
        loc: LocalizationManager,
        onRename: @escaping (String) -> Bool,
        onActivate: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.isActive = isActive
        self.loc = loc
        self.onRename = onRename
        self.onActivate = onActivate
        self.onRemove = onRemove
        _draftLabel = State(initialValue: account.displayLabel)
    }

    var body: some View {
        HStack(spacing: 12) {
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
