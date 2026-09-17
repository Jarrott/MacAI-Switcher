import Foundation
import ServiceManagement

/// Wraps SMAppService for the "Launch at Login" toggle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable the login item and return the authoritative resulting
    /// state. Errors are logged without letting the menu display a false toggle.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error)")
        }
        return isEnabled
    }
}
