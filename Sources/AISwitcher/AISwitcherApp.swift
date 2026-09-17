import AppKit
import SwiftUI

enum AppWindowID {
    static let addAccount = "add-account"
    static let accountSettings = "account-settings"
}

/// Owns startup work that must begin only after AppKit has finished launching.
@MainActor
final class AISwitcherAppDelegate: NSObject, NSApplicationDelegate {
    private var startupTask: Task<Void, Never>?

    /// Discover live provider credentials, refresh usage, and start periodic refresh.
    ///
    /// - Parameter notification: AppKit launch-completion notification.
    /// - Side effects: Reconciles persisted account state, performs provider requests,
    ///   and installs the five-minute refresh task. Repeated callbacks replace prior work.
    func applicationDidFinishLaunching(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = Task { @MainActor in
            await AccountsManager.shared.discoverLiveAccounts()
            guard !Task.isCancelled else { return }
            await AccountsManager.shared.refreshAll()
            guard !Task.isCancelled else { return }
            AccountsManager.shared.startAutoRefresh()
        }
    }

    /// Cancel unfinished startup work before AppKit tears down the process.
    ///
    /// - Parameter notification: AppKit termination notification.
    /// - Side effects: Flushes accumulated runtime to SQLite, cancels startup work,
    ///   and terminates unfinished browser-login processes.
    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        CLIBrowserLoginService.cancelAll()
        AppRuntime.saveBeforeExit()
    }
}

/// Real entry point. If a render was requested (AISWITCHER_RENDER set),
/// produce the PNG and exit; otherwise launch the menu-bar app.
@main
enum Main {
    /// Dispatch the read-only Keychain metadata helper or start the normal application.
    /// The internal helper accepts only the Claude service and exits before UI, account,
    /// runtime or network initialization; stdout contains permission metadata only.
    static func main() {
        // This read-only helper must exit before starting the UI, loading accounts,
        // touching runtime storage or scheduling provider requests.
        if CommandLine.arguments.dropFirst().first == "--claude-keychain-metadata" {
            guard CommandLine.arguments.count == 3,
                CommandLine.arguments[2] == ClaudeKeychainStore.service,
                let data = ClaudeKeychainStore.metadataOutput()
            else { exit(1) }
            FileHandle.standardOutput.write(data)
            exit(0)
        }
        if MainActor.assumeIsolated({ PreviewRenderer.runIfRequested() }) {
            exit(0)
        }
        MainActor.assumeIsolated {
            AppRuntime.beginTracking()
        }
        AISwitcherApp.main()
    }
}

struct AISwitcherApp: App {
    @NSApplicationDelegateAdaptor(AISwitcherAppDelegate.self) private var appDelegate
    @State private var accounts = AccountsManager.shared
    @State private var loc = LocalizationManager.shared

    var body: some Scene {
        // Menu bar icon + dropdown window.
        MenuBarExtra {
            MenuContentView(
                accounts: accounts,
                loc: loc,
                onQuit: { NSApp.terminate(nil) }
            )
            .environment(\.locale, loc.locale)
            .id(loc.language)  // rebuild when the language changes
        } label: {
            // Vector switch glyph, rendered as a template so it stays sharp and
            // tints correctly in light and dark menu-bar appearances.
            Image(nsImage: Self.menuBarImage)
        }
        .menuBarExtraStyle(.window)

        Window("Add Account", id: AppWindowID.addAccount) {
            AddAccountView(accounts: accounts, loc: loc)
                .id(loc.language)
        }
        .defaultSize(width: 520, height: 430)
        .windowResizability(.contentSize)

        Window("Account Settings", id: AppWindowID.accountSettings) {
            SettingsView(accounts: accounts, loc: loc)
                .id(loc.language)
        }
        .defaultSize(width: 580, height: 440)
        .windowResizability(.contentSize)

        // Settings window (also reachable via the standard Settings scene).
        Settings {
            SettingsView(accounts: accounts, loc: loc)
                .id(loc.language)
        }
    }

    /// Load the vector menu-bar glyph at its logical point size.
    ///
    /// The SVG is preferred so AppKit rasterizes it at the display's native scale
    /// instead of enlarging an 18-pixel bitmap on Retina screens. The PNG and SF
    /// Symbol paths remain compatibility fallbacks. All variants are template
    /// images, so the system controls their light/dark tint and disabled state.
    private static let menuBarImage: NSImage = {
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
