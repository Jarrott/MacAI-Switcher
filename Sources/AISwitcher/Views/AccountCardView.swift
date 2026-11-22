import SwiftUI

/// One account block in the dropdown: active checkmark, name + plan,
/// two provider usage rows, and (for Codex/Claude) the resets-available line.
struct AccountCardView: View {
    let account: Account
    let isActive: Bool
    let isRefreshing: Bool
    let isResetting: Bool
    let errorMessage: String?
    let locale: Locale
    var canReorder: Bool = false
    var isDragging: Bool = false
    var dragCoordinateSpace: String = "menu-accounts-space"
    var onDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    let onSelect: () -> Void
    let onConsumeReset: (_ creditID: String?) async throws -> UsageService.ResetOutcome

    @State private var titleHovering = false
    @State private var cardHovering = false
    @State private var gripHovering = false
    @State private var resetsHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only the title button switches accounts; the trailing drag handle reorders.
            HStack(spacing: 4) {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13.25, weight: .regular))
                            .foregroundStyle(.white.opacity(0.97))
                            .opacity(isActive ? 1 : 0)
                            .frame(width: 14)

                        Text(account.displayLabel)
                            .font(.system(size: 15.25, weight: .regular))
                            .foregroundStyle(.white.opacity(0.97))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        Text(account.plan.displayName.uppercased())
                            .font(.system(size: 9.5, weight: .regular))
                            .tracking(0.35)
                            .foregroundStyle(account.provider.menuAccentColor.opacity(0.96))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(account.provider.menuAccentColor.opacity(0.12))
                            }
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        account.provider.menuAccentColor.opacity(0.22),
                                        lineWidth: 0.6
                                    )
                            }

                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.65))
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                    .background(
                        MenuRowBackground(
                            isHighlighted: titleHovering && !isDragging,
                            cornerRadius: 5
                        )
                    )
                }
                .buttonStyle(.plain)
                .onHover { titleHovering = $0 }
                .accessibilityLabel(titleText)
                .accessibilityValue(isActive ? appLocalized("card.active") : "")

                if canReorder {
                    reorderGrip
                }
            }

            usageRowsSection

            if showsResetsRow {
                if canConsumeReset {
                    Button {
                        requestResetConfirmation()
                    } label: {
                        HStack(spacing: 7) {
                            Text(resetsText)
                            Spacer(minLength: 6)
                            if isResetting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white.opacity(0.82))
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .regular))
                                    .opacity(0.72)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.leading, 21)
                        .padding(.trailing, 9)
                        .contentShape(Rectangle())
                        .background(
                            MenuRowBackground(
                                isHighlighted: resetsHovering && !isDragging,
                                restingOpacity: 0.045
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.75, weight: .regular))
                    .foregroundStyle(.white.opacity(0.97))
                    .onHover { resetsHovering = $0 }
                    .disabled(isResetting)
                    .accessibilityHint(appLocalized("card.reset.confirm.hint"))
                } else {
                    Text(resetsText)
                        .font(.system(size: 13.75, weight: .regular))
                        .foregroundStyle(.white.opacity(resetsTextOpacity))
                        .padding(.leading, 21)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.75, weight: .regular))
                    .foregroundStyle(Color.orange.opacity(0.88))
                    .lineLimit(2)
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, 8.5)
        .padding(.horizontal, 3)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.085))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                account.provider.menuAccentColor.opacity(0.55),
                                lineWidth: 1
                            )
                    }
            }
        }
        .shadow(
            color: isDragging ? Color.black.opacity(0.32) : .clear,
            radius: isDragging ? 6 : 0,
            y: isDragging ? 3 : 0
        )
        .onHover { cardHovering = $0 }
    }

    @ViewBuilder
    private var reorderGrip: some View {
        let grip = Image(systemName: "line.3.horizontal")
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(
                .white.opacity(gripHovering || isDragging ? 0.78 : (cardHovering ? 0.44 : 0.22))
            )
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
            .background(
                MenuRowBackground(isHighlighted: gripHovering || isDragging, cornerRadius: 5)
            )
            .onHover { gripHovering = $0 }
            .help(appLocalized("reorder.account_help"))
            .accessibilityHidden(true)

        if let onDragChanged, let onDragEnded {
            grip.gesture(
                DragGesture(
                    minimumDistance: 5,
                    coordinateSpace: .named(dragCoordinateSpace)
                )
                .onChanged(onDragChanged)
                .onEnded { _ in onDragEnded() }
            )
        } else {
            grip
        }
    }

    /// Display-only usage metrics; dragging this area also reorders when multiple accounts exist.
    @ViewBuilder
    private var usageRowsSection: some View {
        let rows = VStack(alignment: .leading, spacing: 5) {
            UsageRow(
                label: primaryWindowLabel,
                window: account.usage.fiveHour,
                locale: locale)
            UsageRow(
                label: secondaryWindowLabel,
                window: account.usage.sevenDay,
                locale: locale)
        }
        .padding(.leading, 21)
        .contentShape(Rectangle())

        if canReorder, let onDragChanged, let onDragEnded {
            rows.gesture(
                DragGesture(
                    minimumDistance: 5,
                    coordinateSpace: .named(dragCoordinateSpace)
                )
                .onChanged(onDragChanged)
                .onEnded { _ in onDragEnded() }
            )
        } else {
            rows
        }
    }

    private var primaryWindowLabel: String {
        switch account.provider {
        case .gemini:
            if AntigravityUsageStore.isAntigravityAccountID(account.accountID) {
                return appLocalized("card.window.5h")
            }
            return appLocalized("card.window.gemini_pro")
        case .codex, .claude:
            return appLocalized("card.window.5h")
        }
    }

    private var secondaryWindowLabel: String {
        switch account.provider {
        case .gemini:
            if AntigravityUsageStore.isAntigravityAccountID(account.accountID) {
                return appLocalized("card.window.7d")
            }
            return appLocalized("card.window.gemini_flash")
        case .codex, .claude:
            return appLocalized("card.window.7d")
        }
    }

    private var showsResetsRow: Bool {
        account.provider != .gemini
    }

    private var titleText: String {
        "\(account.displayLabel) (\(account.plan.displayName))"
    }

    private var resetsText: String {
        guard let n = account.usage.resetsAvailable else {
            return appLocalized("card.resets_unavailable")
        }
        if n == 1 { return appLocalized("card.resets_available.one") }
        return String(format: appLocalized("card.resets_available"), n)
    }

    private var resetsTextOpacity: Double {
        guard let resets = account.usage.resetsAvailable else { return 0.48 }
        return resets > 0 ? 0.88 : 0.50
    }

    private var canConsumeReset: Bool {
        account.provider == .codex && (account.usage.resetsAvailable ?? 0) > 0
    }

    /// Present confirmation after the menu-button action returns, then mutate only
    /// when AppKit reports the destructive button response.
    ///
    /// This deliberately avoids SwiftUI `.alert` because `MenuBarExtra` content is
    /// transient and can otherwise leave an orphaned presentation mask on dismissal.
    private func requestResetConfirmation() {
        Task { @MainActor in
            await Task.yield()
            guard ResetCreditAlertPresenter.confirmReset(accountTitle: titleText) else {
                return
            }
            await performReset()
        }
    }

    /// Execute only after the destructive confirmation button is pressed.
    ///
    /// The method passes the nearest-expiring credit when available, maps every
    /// provider outcome to a localized result, and never infers success from errors.
    @MainActor
    private func performReset() async {
        do {
            let creditID = account.usage.resetCredits?.first?.id
            let outcome = try await onConsumeReset(creditID)
            switch outcome {
            case .reset:
                ResetCreditAlertPresenter.showResult(
                    title: appLocalized("card.reset.success.title"),
                    message: appLocalized("card.reset.success.message"),
                    style: .informational
                )
            case .alreadyRedeemed:
                ResetCreditAlertPresenter.showResult(
                    title: appLocalized("card.reset.success.title"),
                    message: appLocalized("card.reset.already_redeemed"),
                    style: .informational
                )
            case .nothingToReset:
                ResetCreditAlertPresenter.showResult(
                    title: appLocalized("card.reset.not_used.title"),
                    message: appLocalized("card.reset.nothing_to_reset"),
                    style: .warning
                )
            case .noCredit:
                ResetCreditAlertPresenter.showResult(
                    title: appLocalized("card.reset.not_used.title"),
                    message: appLocalized("card.reset.no_credit"),
                    style: .warning
                )
            case .wrongProvider:
                ResetCreditAlertPresenter.showResult(
                    title: appLocalized("card.reset.error.title"),
                    message: appLocalized("card.reset.wrong_provider"),
                    style: .critical
                )
            }
        } catch {
            ResetCreditAlertPresenter.showResult(
                title: appLocalized("card.reset.error.title"),
                message: String(
                    format: appLocalized("card.reset.error.message"),
                    (error as? CodexAuthError)?.displayMessage ?? error.localizedDescription
                ),
                style: .critical
            )
        }
    }
}
