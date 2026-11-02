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
    /// - Side effects: Inserts the AppKit-owned status item, reconciles persisted
    ///   account state, performs provider requests, and installs the five-minute
    ///   refresh task. Repeated callbacks replace prior work.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarPanelController.shared.install { AnyView(MenuDropdownRoot()) }
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

/// Root of the status item dropdown, observing shared app state like a scene would.
private struct MenuDropdownRoot: View {
    @State private var accounts = AccountsManager.shared
    @State private var loc = LocalizationManager.shared

    var body: some View {
        MenuContentView(
            accounts: accounts,
            loc: loc,
            onQuit: { NSApp.terminate(nil) }
        )
        .environment(\.locale, loc.locale)
        .id(loc.language)  // rebuild when the language changes
    }
}

struct AISwitcherApp: App {
    @NSApplicationDelegateAdaptor(AISwitcherAppDelegate.self) private var appDelegate
    @State private var accounts = AccountsManager.shared
    @State private var loc = LocalizationManager.shared

    var body: some Scene {
        // The real status item and dropdown are AppKit-owned (`MenuBarPanelController`);
        // see that file for why SwiftUI `MenuBarExtra` is not used for them. This
        // never-inserted placeholder only keeps SwiftUI from auto-opening the first
        // `Window` scene at launch.
        MenuBarExtra("AI Switcher", isInserted: .constant(false)) {
            EmptyView()
        }

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
}
