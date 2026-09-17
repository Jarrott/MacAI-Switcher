import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Guided account import window for current CLI logins and credential files.
struct AddAccountView: View {
    @Bindable var accounts: AccountsManager
    @Bindable var loc: LocalizationManager

    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider = .codex
    @State private var isImporting = false
    @State private var isBrowserLoggingIn = false
    @State private var browserLoginTask: Task<Void, Never>?
    @State private var feedback: Feedback?

    private enum Feedback {
        case success(String)
        case information(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let message), .information(let message), .failure(let message):
                return message
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .information: return .secondary
            case .failure: return .orange
            }
        }

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .information: return "info.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(loc.string("add_account.title"))
                .font(.title2.weight(.semibold))

            Picker(loc.string("settings.provider"), selection: $provider) {
                ForEach(Provider.allCases) { item in
                    Label {
                        Text(item.displayName)
                    } icon: {
                        ProviderBrandMark(provider: item, size: 17)
                    }
                    .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc.string("add_account.login_instructions"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(loginCommand)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(loc.string("add_account.copy_command")) {
                            copyLoginCommand()
                        }
                        Button(loc.string("add_account.open_terminal")) {
                            copyLoginCommand()
                            openTerminal()
                        }
                    }
                }
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    browserLoginTask = Task { await loginWithBrowser() }
                } label: {
                    Label(
                        loc.string("add_account.browser_login"),
                        systemImage: "safari"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)

                Button {
                    Task { await importCurrentLogin() }
                } label: {
                    Label(
                        loc.string("add_account.import_current"),
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    chooseCredentialFile()
                } label: {
                    Label(
                        loc.string("add_account.import_file"),
                        systemImage: "doc.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        loc.string(
                            isBrowserLoggingIn
                                ? "add_account.browser_waiting"
                                : "add_account.importing"
                        )
                    )
                    .foregroundStyle(.secondary)
                    if isBrowserLoggingIn {
                        Spacer()
                        Button(loc.string("settings.cancel")) {
                            browserLoginTask?.cancel()
                        }
                        .controlSize(.small)
                    }
                }
            } else if let feedback {
                Label(feedback.message, systemImage: feedback.symbol)
                    .font(.callout)
                    .foregroundStyle(feedback.color)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(loc.string("settings.done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 430)
        .environment(\.locale, loc.locale)
        .onChange(of: provider) { _, _ in feedback = nil }
        .onDisappear {
            browserLoginTask?.cancel()
            browserLoginTask = nil
        }
    }

    private var loginCommand: String {
        provider.loginCommand
    }

    private var isBusy: Bool {
        isImporting || isBrowserLoggingIn
    }

    /// Run the provider CLI's official OAuth flow in the default browser, then
    /// commit a validated staged credential and refresh the new account's usage.
    /// Codex OAuth remains isolated from the current live credential until commit.
    private func loginWithBrowser() async {
        isBrowserLoggingIn = true
        feedback = nil
        defer {
            isBrowserLoggingIn = false
            browserLoginTask = nil
        }

        let rollbackAccount = await accounts.prepareBrowserLoginRollback(provider: provider)

        do {
            let loginResult = try await CLIBrowserLoginService.login(provider: provider)
            let result: AccountsManager.ImportResult
            switch loginResult {
            case .stagedCredential(let data):
                result = try await accounts.importCredentialData(
                    provider: provider,
                    data: data,
                    activate: true
                )
            case .liveCredential:
                guard let imported = await accounts.importCurrentAccount(provider: provider) else {
                    feedback = .failure(
                        rollbackMessage(
                            rollbackAccount: rollbackAccount,
                            original: loc.string("add_account.browser_no_credential")
                        )
                    )
                    return
                }
                result = imported
            }
            await accounts.refreshAll()
            feedback = successFeedback(for: result)
        } catch let error as AccountsManager.ImportError {
            feedback = .failure(
                rollbackMessage(
                    rollbackAccount: rollbackAccount,
                    original: localizedMessage(for: error)
                )
            )
        } catch let error as CLIBrowserLoginService.LoginError {
            feedback = .failure(
                rollbackMessage(
                    rollbackAccount: rollbackAccount,
                    original: localizedMessage(for: error)
                )
            )
        } catch is CancellationError {
            let message = rollbackMessage(
                rollbackAccount: rollbackAccount,
                original: loc.string("add_account.browser_cancelled")
            )
            feedback = .information(message)
        } catch {
            feedback = .failure(
                rollbackMessage(
                    rollbackAccount: rollbackAccount,
                    original: error.localizedDescription
                )
            )
        }
    }

    /// Describe recovery from failed OAuth and restore only providers that used live storage.
    ///
    /// - Parameters:
    ///   - rollbackAccount: Credential snapshot captured before browser login.
    ///   - original: Localized reason the login did not complete.
    /// - Returns: Failure text confirming isolation or rollback state.
    /// - Side effects: Codex has none because its temporary home never touched the
    ///   live credential; non-isolated providers restore the captured snapshot.
    private func rollbackMessage(rollbackAccount: Account?, original: String) -> String {
        if CLIBrowserLoginService.isolatedHomeEnvironmentVariable(for: provider) != nil {
            return original + " " + loc.string("add_account.browser_restored")
        }
        guard let rollbackAccount else { return original }
        if accounts.rollbackBrowserLogin(to: rollbackAccount) {
            return original + " " + loc.string("add_account.browser_restored")
        }
        return loc.string("add_account.browser_restore_failed")
    }

    /// Import the provider's live credential and refresh all usage on success.
    private func importCurrentLogin() async {
        isImporting = true
        defer { isImporting = false }

        guard let result = await accounts.importCurrentAccount(provider: provider) else {
            feedback = .failure(loc.string("add_account.no_current_login"))
            return
        }
        await accounts.refreshAll()
        feedback = successFeedback(for: result)
    }

    /// Present a native JSON file picker and import the selected credential.
    private func chooseCredentialFile() {
        let panel = NSOpenPanel()
        panel.title = loc.string("add_account.file_picker_title")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await importCredentialFile(url) }
    }

    /// Validate and securely snapshot a selected credential without activating it.
    private func importCredentialFile(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await accounts.importCredentialFile(provider: provider, url: url)
            await accounts.refreshAll()
            feedback = successFeedback(for: result)
        } catch let importError as AccountsManager.ImportError {
            feedback = .failure(localizedMessage(for: importError))
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    private func successFeedback(for result: AccountsManager.ImportResult) -> Feedback {
        let format: String
        switch result {
        case .added: format = loc.string("add_account.added")
        case .updated: format = loc.string("add_account.updated")
        }
        return .success(String(format: format, result.account.displayLabel))
    }

    private func localizedMessage(for error: AccountsManager.ImportError) -> String {
        switch error {
        case .unreadableFile: return loc.string("add_account.error.unreadable_file")
        case .invalidCredential: return loc.string("add_account.error.invalid_credential")
        case .missingAccountIdentity: return loc.string("add_account.error.missing_identity")
        case .snapshotWriteFailed: return loc.string("add_account.error.snapshot_failed")
        case .activationFailed: return loc.string("add_account.error.activation_failed")
        }
    }

    private func localizedMessage(for error: CLIBrowserLoginService.LoginError) -> String {
        switch error {
        case .executableNotFound: return loc.string("add_account.browser_cli_missing")
        case .launchFailed: return loc.string("add_account.browser_launch_failed")
        case .runtimeNotFound: return loc.string("add_account.browser_runtime_missing")
        case .stagingUnavailable: return loc.string("add_account.browser_staging_failed")
        case .credentialNotCreated: return loc.string("add_account.browser_no_credential")
        case .unsuccessfulExit(let status):
            return String(format: loc.string("add_account.browser_failed"), status)
        }
    }

    private func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loginCommand, forType: .string)
        feedback = .information(loc.string("add_account.command_copied"))
    }

    private func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if !NSWorkspace.shared.open(terminal) {
            feedback = .failure(loc.string("add_account.terminal_failed"))
        }
    }
}
