import AppKit
import SwiftUI

/// AppKit-owned status item and dropdown panel replacing SwiftUI `MenuBarExtra`.
///
/// On macOS 26 and later, `MenuBarExtra` with the window style can desynchronize
/// from its ordered-out window: the status item stays highlighted, the window is
/// still considered presented, and further clicks never reopen it. Owning the
/// `NSStatusItem`, its highlight, and the panel lifecycle in one place keeps the
/// visible state and the presentation state identical.
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    static let shared = MenuBarPanelController()

    /// Posted after the dropdown panel has been ordered out for any reason.
    static let didCloseNotification = Notification.Name("AISwitcher.menuPanelDidClose")

    /// Fixed dropdown width shared with `MenuContentView`.
    static let panelWidth: CGFloat = 320

    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    private var makeContent: (() -> AnyView)?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var lastContentSize: CGSize = .zero

    /// Whether the dropdown panel is currently presented.
    private(set) var isOpen = false

    private override init() {
        super.init()
    }

    /// Insert the status item and prepare the dropdown panel.
    ///
    /// - Parameter content: Builder for the dropdown's root SwiftUI view. It runs
    ///   once per presentation so state resets exactly like `MenuBarExtra`.
    /// - Side effects: Adds a system status bar item. Repeated calls only replace
    ///   the content builder.
    func install(content: @escaping () -> AnyView) {
        makeContent = content
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarImage
            button.imagePosition = .imageOnly
            button.toolTip = "AI Switcher"
            button.setAccessibilityLabel("AI Switcher")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Present the dropdown if hidden, otherwise dismiss it.
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Present the dropdown below the status item and highlight the item.
    ///
    /// - Side effects: Rebuilds the SwiftUI content, makes the panel key without
    ///   activating the app, and installs outside-click and Escape monitors.
    func open() {
        guard !isOpen, let makeContent, let button = statusItem?.button else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        lastContentSize = .zero
        let root = MenuPanelRoot(content: makeContent()) { [weak self] size in
            self?.contentSizeDidChange(size)
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        // SwiftUI usually reports its measured size synchronously during the layout
        // above, before the panel is open; prefer it over the empty fitting size.
        var size = lastContentSize
        if size.width <= 0 || size.height <= 0 { size = hostingView.fittingSize }
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: Self.panelWidth, height: 200)
        }
        lastContentSize = size
        panel.setFrame(panelFrame(for: size), display: false)

        isOpen = true
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    /// Dismiss the dropdown and clear the status item highlight.
    ///
    /// - Side effects: Orders the panel out, removes event monitors, and posts
    ///   `didCloseNotification`. The hosted view is released on the next `open()`,
    ///   never while one of its actions may still be executing.
    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        NotificationCenter.default.post(name: Self.didCloseNotification, object: nil)
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    // MARK: - Panel

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// Screen frame for the dropdown anchored to the status item's menu bar slot.
    ///
    /// - Parameter size: Desired content size in points.
    /// - Returns: A frame whose top touches the bottom of the menu bar, left-aligned
    ///   with the status item and clamped inside the item's screen.
    private func panelFrame(for size: CGSize) -> NSRect {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return NSRect(origin: .zero, size: size)
        }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.minX
        let y = buttonWindow.frame.minY - size.height
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(x, visible.maxX - size.width - 4)
            x = max(x, visible.minX + 4)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Record the content size and, while open, keep the panel's top edge attached to
    /// the menu bar. Sizes reported before presentation are used by `open()`.
    private func contentSizeDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != lastContentSize else { return }
        lastContentSize = size
        guard isOpen, let panel else { return }
        panel.setFrame(panelFrame(for: size), display: true)
    }

    // MARK: - Dismissal

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel else {
                return event
            }
            self.close()
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    /// Close when key status moves to a window that is not part of the dropdown.
    ///
    /// Popovers presented from the dropdown are child windows of the panel and may
    /// take key status; they must not dismiss their own parent. The check is
    /// deferred one run-loop turn so `NSApp.keyWindow` already reflects the new
    /// key window.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard self.isOpen, let panel = self.panel, !panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, Self.window(key, isAttachedTo: panel) { return }
            self.close()
        }
    }

    private static func window(_ window: NSWindow, isAttachedTo panel: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return false
    }

    // MARK: - Artwork

    /// Load the vector menu-bar glyph at its logical point size.
    ///
    /// The SVG is preferred so AppKit rasterizes it at the display's native scale
    /// instead of enlarging an 18-pixel bitmap on Retina screens. The PNG and SF
    /// Symbol paths remain compatibility fallbacks. All variants are template
    /// images, so the system controls their light/dark tint and disabled state.
    static let menuBarImage: NSImage = {
        if let image = loadMenuBarImage(from: .main) { return image }
        if let image = loadMenuBarImage(from: .module) { return image }
        let fallback =
            NSImage(
                systemSymbolName: "arrow.left.arrow.right",
                accessibilityDescription: "AI Switcher")
            ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()

    /// Load the preferred menu-bar artwork from one resource bundle.
    ///
    /// - Parameter bundle: Packaged app resources or SwiftPM development resources.
    /// - Returns: An 18-point template image, or `nil` when no candidate exists.
    private static func loadMenuBarImage(from bundle: Bundle) -> NSImage? {
        let candidates = [
            (name: "MenuBarTemplate", extension: "svg"),
            (name: "MenuBarTemplate@2x", extension: "png"),
            (name: "MenuBarTemplate", extension: "png"),
        ]
        for candidate in candidates {
            if let url = bundle.url(
                forResource: candidate.name,
                withExtension: candidate.extension
            ), let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                return image
            }
        }
        return nil
    }
}

/// Borderless non-activating panel that can still become key, so keyboard
/// shortcuts inside the dropdown work without activating the agent app.
private final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Hosts the dropdown content and reports its natural size to the controller.
private struct MenuPanelRoot: View {
    let content: AnyView
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                onSizeChange(size)
            }
    }
}
