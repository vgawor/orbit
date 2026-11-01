import ServiceManagement

/// Start Orbit when you log in. Uses macOS's login items (System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil when it worked.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Allow Orbit in System Settings → Login Items."
            }
            return error.localizedDescription
        }
    }

    /// Only the copy in /Applications should start at login, not a build folder copy.
    static var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
}
