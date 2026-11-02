import AppKit
import SwiftUI

/// Zero-size AppKit bridge that removes the opaque backing color SwiftUI can
/// install behind a menu-bar window or popover.
///
/// The bridge changes only the containing window's background surface. It does
/// not alter activation, focus, sizing, shadows, or event handling. This allows
/// a behind-window visual-effect view to sample the actual desktop content
/// instead of blurring an intermediate solid window color.
private struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TransparentWindowProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TransparentWindowProbeView)?.configureContainingWindow()
    }
}

/// Reapplies transparency whenever SwiftUI moves the hosted content to a new
/// ephemeral MenuBarExtra or popover window.
private final class TransparentWindowProbeView: NSView {
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        stopObservingWindow()
        super.viewDidMoveToWindow()

        guard let window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        configureContainingWindow()
        schedulePostPresentationConfiguration()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        configureContainingWindow()
    }

    /// Make the containing presentation surface transparent without changing
    /// any window behavior owned by SwiftUI.
    ///
    /// - Side effects: Clears the NSWindow and its hosting content layer. The
    ///   call is idempotent and must run on AppKit's main actor.
    func configureContainingWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.layer?.isOpaque = false
    }

    /// Reapply transparency after SwiftUI has finished ordering or activating
    /// its ephemeral presentation window.
    ///
    /// - Parameter notification: Window lifecycle notification for this probe's
    ///   current window.
    /// - Side effects: Restores the clear backing layer if SwiftUI replaced it.
    @objc private func windowPresentationDidChange(_ notification: Notification) {
        configureContainingWindow()
        schedulePostPresentationConfiguration()
    }

    /// Schedule one next-run-loop pass after SwiftUI applies presentation style.
    private func schedulePostPresentationConfiguration() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(configureAfterPresentation),
            object: nil
        )
        perform(#selector(configureAfterPresentation), with: nil, afterDelay: 0)
    }

    /// Clear the final backing layer installed during the presentation pass.
    @objc private func configureAfterPresentation() {
        configureContainingWindow()
    }

    /// Stop observing the prior ephemeral window before SwiftUI rehosts the view.
    private func stopObservingWindow() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(configureAfterPresentation),
            object: nil
        )
        let observedWindow = observedWindow
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: observedWindow
        )
        self.observedWindow = nil
    }
}

/// SwiftUI wrapper around NSVisualEffectView for the translucent menu background.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var alphaValue: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        v.alphaValue = alphaValue
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
        nsView.isEmphasized = false
        nsView.alphaValue = alphaValue
    }
}

/// Neutral translucent surface shared by interactive rows in the menu and submenu.
/// Keeping this independent of the system accent color prevents a saturated blue
/// selection block while preserving a clear hover affordance over the dark glass.
struct MenuRowBackground: View {
    let isHighlighted: Bool
    var restingOpacity: Double = 0
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(isHighlighted ? 0.12 : restingOpacity))
    }
}

/// Reusable dark glass treatment shared by the menu and auxiliary popovers.
/// The visual-effect view preserves desktop color and motion while the cool
/// tint keeps text legible over bright browser windows.
private struct MenuGlassPanelModifier: ViewModifier {
    let solidBackground: Bool
    let cornerRadius: CGFloat
    let castsShadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    if solidBackground {
                        Color(red: 0.075, green: 0.092, blue: 0.11)
                    } else {
                        TransparentWindowConfigurator()
                            .frame(width: 0, height: 0)

                        // Apply translucency inside AppKit so live display and
                        // screenshots use the same WindowServer composition.
                        VisualEffectBlur(
                            material: .menu,
                            blending: .behindWindow,
                            alphaValue: 0.60
                        )
                        Color(red: 0.02, green: 0.04, blue: 0.06).opacity(0.32)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.00768),
                                Color.clear,
                                Color.black.opacity(0.01152),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75)
            }
            .presentationBackground(.clear)
            .shadow(
                color: castsShadow ? Color.black.opacity(0.38) : .clear,
                radius: castsShadow ? 16 : 0,
                x: 0,
                y: castsShadow ? 7 : 0
            )
    }
}

extension View {
    /// Apply the production menu glass with a solid offscreen-render fallback.
    ///
    /// - Parameters:
    ///   - solidBackground: Disable live blur when no WindowServer backdrop exists.
    ///   - cornerRadius: Continuous panel radius in points.
    ///   - castsShadow: Whether the panel owns the outer floating shadow.
    /// - Returns: This view styled as a consistent AI Switcher glass panel.
    func menuGlassPanel(
        solidBackground: Bool,
        cornerRadius: CGFloat = 14,
        castsShadow: Bool = true
    ) -> some View {
        modifier(
            MenuGlassPanelModifier(
                solidBackground: solidBackground,
                cornerRadius: cornerRadius,
                castsShadow: castsShadow
            )
        )
    }
}
