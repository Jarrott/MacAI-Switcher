import SwiftUI

/// Branded menu section that groups every managed account for one provider.
struct ProviderSectionView<Content: View>: View {
    let provider: Provider
    @ViewBuilder let content: Content

    /// Create a provider section around account cards supplied by the menu.
    ///
    /// - Parameters:
    ///   - provider: Provider whose artwork and accent identify the section.
    ///   - content: Account cards and their noninteractive separators.
    init(provider: Provider, @ViewBuilder content: () -> Content) {
        self.provider = provider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderBrandBadge(provider: provider, size: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.companyDisplayName.uppercased())
                        .font(.system(size: 9.5, weight: .regular))
                        .tracking(0.8)
                        .foregroundStyle(provider.menuAccentColor.opacity(0.95))

                    Text(provider.displayName)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            provider.menuAccentColor.opacity(0.38),
                            Color.white.opacity(0.10),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.75)
                .padding(.horizontal, 9)

            content
        }
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay {
                    LinearGradient(
                        colors: [
                            provider.menuAccentColor.opacity(0.105),
                            provider.menuAccentColor.opacity(0.025),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(provider.menuAccentColor.opacity(0.20), lineWidth: 0.75)
        }
    }
}
