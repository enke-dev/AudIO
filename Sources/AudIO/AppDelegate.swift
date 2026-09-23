import AppKit
import Combine
import SwiftUI

/// Status item + NSPopover instead of `MenuBarExtra(.window)`: the popover resizes
/// cleanly with its SwiftUI content, where the MenuBarExtra panel leaves ghost frames.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var router: Router?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status item first: the router's first Core Audio queries can block if coreaudiod
        // hangs – the icon should still appear.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        setIcon("hifispeaker.2")

        let router = Router()
        self.router = router

        let hosting = NSHostingController(rootView: MenuView().environmentObject(router))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        statusSubscription = router.$status.combineLatest(router.$isInstallingDriver)
            .sink { [weak self] status, isInstalling in
                guard let self else { return }
                let symbol = if isInstalling { "arrow.down.circle" }
                    else if case .routing = status { "hifispeaker.2.fill" }
                    else { "hifispeaker.2" }
                self.setIcon(symbol)
                // The password prompt closes the popover – show the result when done.
                if self.wasInstalling, !isInstalling { self.showPopover() }
                self.wasInstalling = isInstalling
            }
    }

    private var wasInstalling = false

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudIO")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(from: button)
        }
    }

    private func showPopover(from button: NSStatusBarButton? = nil) {
        guard let button = button ?? statusItem?.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
