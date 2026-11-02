import AppKit
import SwiftUI

/// Provider-specific presentation metadata used by account-management surfaces.
extension Provider {
    /// Company name shown above the provider product name in the compact menu.
    var companyDisplayName: String {
        switch self {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        }
    }

    /// Accent reserved for section borders, labels, and low-opacity backgrounds.
    /// Provider artwork keeps its official source colors and is never recolored.
    var menuAccentColor: Color {
        switch self {
        case .codex:
            return Color(red: 0.28, green: 0.78, blue: 0.71)
        case .claude:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }

    /// Packaged SVG name for the provider's official compact artwork.
    fileprivate var artworkResourceName: String {
        switch self {
        case .codex: return "ProviderOpenAI"
        case .claude: return "ProviderClaude"
        }
    }
}

/// Official compact provider artwork with an SF Symbol fallback for damaged bundles.
struct ProviderBrandMark: View {
    let provider: Provider
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let artwork = ProviderBrandArtwork.image(for: provider) {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(provider == .codex ? 1.45 : 1)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .fill(provider.menuAccentColor.opacity(0.20))
                    Image(systemName: provider.symbolName)
                        .font(.system(size: size * 0.48, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Branded container that gives both provider marks equal visual weight in rows.
struct ProviderBrandBadge: View {
    let provider: Provider
    var size: CGFloat = 30

    var body: some View {
        ProviderBrandMark(provider: provider, size: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                provider.menuAccentColor.opacity(0.22),
                                Color.white.opacity(0.035),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.65)
            }
    }
}

/// Loads each provider asset once from either an assembled app or SwiftPM bundle.
private enum ProviderBrandArtwork {
    private static let openAI = load(resource: Provider.codex.artworkResourceName)
    private static let claude = load(resource: Provider.claude.artworkResourceName)

    /// Return cached artwork for a provider without reading credential or app state.
    static func image(for provider: Provider) -> NSImage? {
        switch provider {
        case .codex: return openAI
        case .claude: return claude
        }
    }

    /// Resolve one SVG from production resources, then the SwiftPM development bundle.
    private static func load(resource: String) -> NSImage? {
        // `Bundle.module` traps when the SwiftPM resource bundle is absent, so it
        // is only consulted after the packaged app resources miss.
        if let image = load(resource: resource, from: .main) { return image }
        return load(resource: resource, from: .module)
    }

    private static func load(resource: String, from bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: resource, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
