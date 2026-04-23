import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+). Uses the modern
/// login-item API — no helper bundle, no separate plist, just a toggle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    Log.info("app", "launch-at-login registered")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    Log.info("app", "launch-at-login unregistered")
                }
            }
        } catch {
            Log.error("app", "launch-at-login failed: \(error.localizedDescription)")
        }
    }
}
