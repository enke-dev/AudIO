import AppKit
import Combine
import SwiftUI

/// The status item and its panel (`MenuPanel` showing `MenuView`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var router: Router?
    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var statusSubscription: AnyCancellable?
    private var clickMonitor: Any?
    private var wasInstalling = false

    func applicationWillTerminate(_ notification: Notification) {
        panelLog.notice("terminating")
        // Quitting with the panel open (⌘Q, a rebuild, an update) must end its status item
        // session first – one left open by a gone process keeps the menu bar stuck
        // (revealed in full screen, no hover reveal) until the next login.
        panel?.dismiss()
        panel?.hide()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelLog.notice("launched \(Bundle.main.bundlePath, privacy: .public)")
        quitOtherInstances()

        // Status item first: the router's first Core Audio queries can block if coreaudiod
        // hangs – the icon should still appear.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        setIcon("hifispeaker.2")

        let router = Router()
        self.router = router
        let panel = MenuPanel(rootView: MenuView(close: { [weak self] in self?.panel?.dismiss() }).environmentObject(router))
        self.panel = panel

        #if compiler(>=6.4) // macOS 27 SDK
        if #available(macOS 27.0, *) {
            // The system runs the panel like its own menus: it highlights the icon, keeps an
            // auto-hidden menu bar revealed and handles clicks on the icon while open.
            item.expandedInterfaceDelegate = self
            panel.managesHighlight = false
            panel.requestClose = { [weak item] in
                guard let session = item?.expandedInterfaceSession else { return false }
                panelLog.notice("cancel session")
                session.cancel()
                return true
            }
            return subscribe(to: router)
        }
        #endif

        // Before macOS 27: handle clicks on the icon before the button does and swallow them:
        // a tracked click makes the button reset its highlight on mouse-up, but it should stay
        // lit while the panel is open (like the system menus).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window != nil, event.window == self.statusItem?.button?.window else { return false }
                self.togglePanel()
                return true
            }
            return handled ? nil : event
        }
        subscribe(to: router)
    }

    private func subscribe(to router: Router) {
        statusSubscription = router.$status.combineLatest(router.$isInstallingDriver)
            .sink { [weak self] status, isInstalling in
                guard let self else { return }
                let symbol = if isInstalling { "arrow.down.circle" }
                    else if case .routing = status { "hifispeaker.2.fill" }
                    else { "hifispeaker.2" }
                self.setIcon(symbol)
                // The password prompt closes the panel – show the result when done.
                if self.wasInstalling, !isInstalling { self.showPanel() }
                self.wasInstalling = isInstalling
            }
    }

    /// One AudIO at a time: two copies (the login item and a fresh build, say) would both
    /// route audio and fight over the panel's menu bar session. The newest wins – the others
    /// quit (restoring the sound output) before this one starts routing.
    private func quitOtherInstances() {
        // Bare builds (Xcode, `swift run`) have no bundle ID – match their executable too.
        let others = NSWorkspace.shared.runningApplications.filter { app in
            app != .current && (app.bundleIdentifier == "dev.enke.AudIO"
                || (app.bundleIdentifier == nil && app.executableURL?.lastPathComponent == "AudIO"))
        }
        guard !others.isEmpty else { return }
        panelLog.notice("quitting \(others.count, privacy: .public) other instance(s)")
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudIO")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.dismiss()
        } else if Date().timeIntervalSince(panel.lastDismissal) > 0.3 {
            // (a click on the icon that just closed the panel by taking focus shouldn't reopen it)
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel, let button = statusItem?.button, !panel.isVisible else { return }
        panel.show(below: button)
    }
}

#if compiler(>=6.4) // macOS 27 SDK
@available(macOS 27.0, *)
extension AppDelegate: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        panelLog.notice("session began")
        // A click on the icon while open may first close the panel by taking its focus –
        // that click must not reopen it right away. (Cancelled after the callback returns.)
        if let panel, Date().timeIntervalSince(panel.lastDismissal) < 0.3 {
            panelLog.notice("session began right after closing – cancelling")
            DispatchQueue.main.async { expandedInterfaceSession.cancel() }
            return
        }
        showPanel()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        panelLog.notice("session ended")
        panel?.hide()
    }
}
#endif
