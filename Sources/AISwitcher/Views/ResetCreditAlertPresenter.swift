import AppKit

/// Presents reset-credit confirmation and result dialogs outside the transient
/// SwiftUI `MenuBarExtra` hierarchy.
///
/// Native modal alerts own their complete lifecycle, so dismissing the menu cannot
/// orphan a SwiftUI presentation mask or leave an unclickable Cancel button behind.
@MainActor
enum ResetCreditAlertPresenter {
    /// Ask for explicit confirmation before the irreversible provider mutation.
    ///
    /// - Parameter accountTitle: Display-only account name included in the warning.
    /// - Returns: `true` only when the destructive confirmation button is pressed.
    /// - Side effects: Activates the app and temporarily runs an AppKit modal event loop.
    static func confirmReset(accountTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = appLocalized("card.reset.confirm.title")
        alert.informativeText = String(
            format: appLocalized("card.reset.confirm.message"),
            accountTitle
        )

        let confirmButton = alert.addButton(
            withTitle: appLocalized("card.reset.confirm.action")
        )
        confirmButton.hasDestructiveAction = true

        let cancelButton = alert.addButton(
            withTitle: appLocalized("card.reset.confirm.cancel")
        )
        cancelButton.keyEquivalent = "\u{1b}"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // `runModal()` normally orders the alert out. Explicitly remove the window
        // as well so cancellation cannot leave an AppKit modal surface alive.
        alert.window.orderOut(nil)
        return isConfirmed(response)
    }

    /// Convert an AppKit modal response into the one response allowed to mutate.
    ///
    /// - Parameter response: Button/escape response returned by `NSAlert`.
    /// - Returns: `true` only for the first destructive confirmation button;
    ///   Cancel, Escape, abort, stop, and unknown responses all fail closed.
    static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// Show a non-destructive result message after the provider request completes.
    ///
    /// - Parameters:
    ///   - title: Localized result heading.
    ///   - message: Localized result detail.
    ///   - style: Success/info/error presentation style.
    /// - Side effects: Activates the app and temporarily presents an AppKit alert.
    static func showResult(
        title: String,
        message: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        let dismissButton = alert.addButton(withTitle: appLocalized("card.reset.dismiss"))
        dismissButton.keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
        alert.window.orderOut(nil)
    }
}
