import AppKit
import SwiftUI

/// Offscreen renderer used to verify the UI without a live menu-bar click.
/// Enabled by setting AISWITCHER_RENDER=/path/out.png ; renders the dropdown
/// with mock data for both English and Chinese, then exits.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() -> Bool {
        guard let out = ProcessInfo.processInfo.environment["AISWITCHER_RENDER"] else {
            return false
        }
        let lang = ProcessInfo.processInfo.environment["AISWITCHER_LANG"] ?? "en"
        LocalizationManager.shared.language = AppLanguage(rawValue: lang) ?? .english

        let mgr = AccountsManager(ephemeral: true)
        if ProcessInfo.processInfo.environment["AISWITCHER_REAL"] != nil {
            // Render whatever is actually persisted (real accounts + usage).
            mgr.loadForPreview()
        } else {
            mgr.installMockData()
        }

        let surface = ProcessInfo.processInfo.environment["AISWITCHER_SURFACE"]
        let view: AnyView
        if surface == "account-switcher" {
            view = AnyView(
                AccountSwitcherPopover(
                    accounts: mgr,
                    loc: LocalizationManager.shared,
                    solidBackground: true,
                    onSelect: { _ in },
                    onOpenSettings: {}
                )
                .environment(\.locale, LocalizationManager.shared.locale)
            )
        } else {
            view = AnyView(
                MenuContentView(
                    accounts: mgr,
                    loc: LocalizationManager.shared,
                    onQuit: {},
                    solidBackground: true
                )
                .environment(\.locale, LocalizationManager.shared.locale)
                .frame(width: 320)
            )
        }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage,
            let tiff = nsImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: out))
            let renderedSurface = surface ?? "menu"
            FileHandle.standardError.write(
                "rendered \(lang) \(renderedSurface) -> \(out)\n".data(using: .utf8)!
            )
        }
        return true
    }
}
