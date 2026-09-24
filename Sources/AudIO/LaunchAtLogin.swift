import ServiceManagement

/// "Open at Login" via the app's own login item (needs the bundled .app).
enum LaunchAtLogin {
    /// Only a real app bundle may register – a bare build (Xcode's DerivedData, `swift run`)
    /// would be opened through Terminal at every login, as an outdated second copy.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        guard isAvailable, enabled != isEnabled else { return }
        if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}
