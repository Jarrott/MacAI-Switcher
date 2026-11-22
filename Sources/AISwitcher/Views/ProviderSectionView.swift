import SwiftUI

/// Branded menu section that groups every managed account for one provider.
/// When multiple provider sections exist, dragging the section header reorders them.
struct ProviderSectionView<Content: View>: View {
    let provider: Provider
    var canReorder: Bool = false
    var isDragging: Bool = false
    var dragCoordinateSpace: String = "menu-accounts-space"
    var onDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    @ViewBuilder let content: Content

    @State private var headerHovering = false

    /// Create a provider section around account cards supplied by the menu.
    init(
        provider: Provider,
        canReorder: Bool = false,
        isDragging: Bool = false,
        dragCoordinateSpace: String = "menu-accounts-space",
        onDragChanged: ((DragGesture.Value) -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.provider = provider
        self.canReorder = canReorder
        self.isDragging = isDragging
        self.dragCoordinateSpace = dragCoordinateSpace
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

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
                .fill(Color.white.opacity(isDragging ? 0.075 : 0.025))
                .overlay {
                    LinearGradient(
                        colors: [
                            provider.menuAccentColor.opacity(isDragging ? 0.18 : 0.105),
                            provider.menuAccentColor.opacity(isDragging ? 0.06 : 0.025),
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
                .strokeBorder(
                    provider.menuAccentColor.opacity(isDragging ? 0.62 : 0.20),
                    lineWidth: isDragging ? 1.15 : 0.75
                )
        }
        .shadow(
            color: isDragging ? Color.black.opacity(0.35) : .clear,
            radius: isDragging ? 8 : 0,
            y: isDragging ? 4 : 0
        )
    }

    @ViewBuilder
    private var sectionHeader: some View {
        let baseHeader = HStack(spacing: 9) {
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

            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(headerHovering || isDragging ? 0.62 : 0.24))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            MenuRowBackground(
                isHighlighted: canReorder && (headerHovering || isDragging),
                cornerRadius: 8
            )
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        )
        .onHover { headerHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(canReorder ? appLocalized("reorder.section_help") : "")

        if canReorder, let onDragChanged, let onDragEnded {
            baseHeader
                .help(appLocalized("reorder.section_help"))
                .gesture(
                    DragGesture(
                        minimumDistance: 5,
                        coordinateSpace: .named(dragCoordinateSpace)
                    )
                    .onChanged(onDragChanged)
                    .onEnded { _ in onDragEnded() }
                )
        } else {
            baseHeader
        }
    }
}
