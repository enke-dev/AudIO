import AppKit

// Plain AppKit entry point: a SwiftUI `App` needs at least one scene, and even an empty
// `Settings` scene opens a window on first launch. The UI lives in the status-item popover.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate() // NSApplication holds its delegate weakly – keep it alive here
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
