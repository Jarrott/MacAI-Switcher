import SwiftUI

/// A single menu action line: title on the left, optional ⌘-shortcut hint or
/// disclosure chevron on the right, with a hover highlight.
struct MenuActionRow: View {
    let title: String
    var shortcut: String? = nil
    var shortcutKey: KeyEquivalent? = nil
    var showsChevron: Bool = false
    var isLoading: Bool = false
    var isEnabled: Bool = true
    var keepsHighlight: Bool = false
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        shortcutConfiguredButton
    }

    private var actionButton: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                Spacer(minLength: 12)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.58))
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12.75, weight: .regular))
                        .foregroundStyle(
                            .white.opacity(isHighlighted ? 0.82 : 0.46)
                        )
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(isHighlighted ? 0.96 : 0.72))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
            .background(
                MenuRowBackground(isHighlighted: isHighlighted)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.66)
        .onHover { isHovering in
            hovering = isHovering
            onHoverChanged?(isHovering)
        }
        .onChange(of: controlActiveState) { _, state in
            guard state == .inactive else { return }
            hovering = false
            onHoverChanged?(false)
        }
    }

    private var isHighlighted: Bool {
        isEnabled && controlActiveState != .inactive && (hovering || keepsHighlight)
    }

    @ViewBuilder
    private var shortcutConfiguredButton: some View {
        if let shortcutKey {
            actionButton.keyboardShortcut(shortcutKey, modifiers: .command)
        } else {
            actionButton
        }
    }
}
