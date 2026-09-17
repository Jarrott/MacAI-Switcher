import SwiftUI

/// Hover-opened account switcher attached to the Account Settings menu row.
/// It mirrors a native macOS submenu: active accounts have checkmarks, rows
/// switch immediately, and the final action opens full account management.
struct AccountSwitcherPopover: View {
    @Bindable var accounts: AccountsManager
    let loc: LocalizationManager
    let solidBackground: Bool
    let onSelect: (Account) -> Void
    let onOpenSettings: () -> Void

    @State private var hoveredAccountID: UUID?
    @State private var settingsHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(accounts.accounts) { account in
                Button {
                    onSelect(account)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .regular))
                            .opacity(accounts.isActive(account) ? 1 : 0)
                            .frame(width: 15)

                        ProviderBrandMark(provider: account.provider, size: 20)

                        Text(Self.title(for: account))
                            .font(.system(size: 14.5, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(.white.opacity(0.97))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(rowBackground(isHovered: hoveredAccountID == account.id))
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredAccountID = isHovering ? account.id : nil
                }
                .accessibilityValue(
                    accounts.isActive(account) ? loc.string("card.active") : ""
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

            Button(action: onOpenSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5, weight: .regular))
                        .frame(width: 15)
                    Text(loc.string("settings.manage_accounts"))
                        .font(.system(size: 14, weight: .regular))
                    Spacer(minLength: 4)
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(rowBackground(isHovered: settingsHovering))
            }
            .buttonStyle(.plain)
            .onHover { settingsHovering = $0 }
        }
        .padding(6)
        .frame(width: 252)
        .menuGlassPanel(
            solidBackground: solidBackground,
            cornerRadius: 12,
            castsShadow: true
        )
        .presentationBackground(.clear)
        .environment(\.locale, loc.locale)
    }

    /// Format one submenu row consistently with the account cards.
    ///
    /// - Parameter account: Managed Codex or Claude account.
    /// - Returns: Display label followed by the provider plan in parentheses.
    nonisolated static func title(for account: Account) -> String {
        "\(account.displayLabel) (\(account.plan.displayName))"
    }

    private func rowBackground(isHovered: Bool) -> some View {
        MenuRowBackground(isHighlighted: isHovered)
    }
}
