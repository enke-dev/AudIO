import AppKit
import Combine
import SwiftUI

/// The status item and its panel (`MenuPanel` showing `MenuView`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var router: Router?
    private let updater = Updater()
    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var statusSubscription: AnyCancellable?
    private var clickMonitor: Any?
    private var wasInstalling = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        panelLog.notice("terminating")
        // Quitting with the panel open (⌘Q, a rebuild, an update) must end its status item
        // session first – one left open by a gone process keeps the menu bar stuck
        // (revealed in full screen, no hover reveal) until the next login.
        panel?.dismiss()
        panel?.hide()
    }

    /// `kill`/`pkill` (SIGTERM) would end the process without `applicationWillTerminate` –
    /// and leave an open panel's session, so the menu bar, stuck. Quit properly instead.
    private func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelLog.notice("launched \(Bundle.main.bundlePath, privacy: .public)")
        quitOtherInstances()
        quitOnTerminationSignal()

        // Status item first: the router's first Core Audio queries can block if coreaudiod
        // hangs – the icon should still appear.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        setIcon("hifispeaker.2")

        let router = Router()
        self.router = router
        let panel = MenuPanel(rootView: MenuView()
            .environmentObject(router)
            .environmentObject(updater))
        self.panel = panel
        updater.start()

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
        statusSubscription = router.$status.combineLatest(router.$isInstallingDriver, router.$isDriverMuted)
            .sink { [weak self] status, isInstalling, isMuted in
                guard let self else { return }
                let symbol = if isInstalling { "arrow.down.circle" }
                    else if case .routing = status { "hifispeaker.2.fill" }
                    else { "hifispeaker.2" }
                // Muted shows on the icon, like the Sound menu's – no need to open the panel.
                self.setIcon(symbol, slashed: isMuted && !isInstalling)
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

    // MARK: - Icon

    private var iconSymbol = "hifispeaker.2"
    /// How much of the mute slash shows, 0…1 – animated like the Sound menu's.
    private var slash: CGFloat = 0
    /// Drawing on (from the top left) or off (towards the bottom right, like the Sound menu's).
    private var isSlashDrawingOn = true
    /// Through the switch, 0…1 – the speaker dips (fades, shrinks) meanwhile, like the Sound
    /// menu's replaces its symbol.
    private var switchProgress: CGFloat = 0
    private var slashAnimation: Task<Void, Never>?

    private func setIcon(_ symbol: String, slashed: Bool = false) {
        iconSymbol = symbol
        let target: CGFloat = slashed ? 1 : 0
        let isFirst = statusItem?.button?.image == nil
        guard target != slash, !isFirst, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            slashAnimation?.cancel()
            slash = target
            switchProgress = 0
            return renderIcon()
        }
        slashAnimation?.cancel()
        let start = slash
        isSlashDrawingOn = target > start
        slashAnimation = Task { [weak self] in
            // ~60 fps, timed by the clock – counting frames drifted late (each wait plus
            // drawing takes longer than a frame), most of all the speaker coming back.
            let begin = ContinuousClock.now
            var t: CGFloat = 0
            while t < 1 {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let elapsed = ContinuousClock.now - begin
                t = min(CGFloat(Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)) / Switch.duration, 1)
                let timeline = self.isSlashDrawingOn ? Switch.muting : Switch.unmuting
                self.slash = start + (target - start) * Self.phase(t, from: timeline.slash.lowerBound, to: timeline.slash.upperBound)
                self.switchProgress = t >= 1 ? 0 : t
                self.renderIcon()
            }
        }
    }

    /// Like the Sound menu's (measured frame by frame, unmuting): the speaker fades away
    /// evenly, then the slash alone is drawn off, a short pause, the speaker comes back
    /// quickly. Muting runs it backwards. In ms, as fractions of the switch.
    private struct Switch {
        let speakerGoes: ClosedRange<CGFloat>
        let slash: ClosedRange<CGFloat>
        let speakerComes: ClosedRange<CGFloat>

        static let duration: CGFloat = 0.54
        static let unmuting = Switch(speakerGoes: ms(0, 180), slash: ms(170, 400), speakerComes: ms(420, 540))
        static let muting = unmuting.reversed

        private static func ms(_ from: CGFloat, _ to: CGFloat) -> ClosedRange<CGFloat> {
            (from / 1000 / duration)...(to / 1000 / duration)
        }

        private var reversed: Switch {
            let flip = { (range: ClosedRange<CGFloat>) in (1 - range.upperBound)...(1 - range.lowerBound) }
            return Switch(speakerGoes: flip(speakerComes), slash: flip(slash), speakerComes: flip(speakerGoes))
        }
    }

    /// `t` mapped onto `from…to`, eased in and out – 0 before, 1 after.
    private static func phase(_ t: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let local = min(max((t - from) / (to - from), 0), 1)
        return local < 0.5 ? 2 * local * local : 1 - pow(-2 * local + 2, 2) / 2
    }

    /// How far the speaker is faded and shrunk: going (evenly), gone, coming back.
    private static func dip(_ t: CGFloat, _ timeline: Switch) -> CGFloat {
        guard t > 0 else { return 0 }
        let linear = { (range: ClosedRange<CGFloat>) in min(max((t - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1) }
        return linear(timeline.speakerGoes) - phase(t, from: timeline.speakerComes.lowerBound, to: timeline.speakerComes.upperBound)
    }

    private func renderIcon() {
        guard let base = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: "AudIO") else { return }
        // The part of the slash's line that shows: grows from its start, or shrinks to its end.
        let part = isSlashDrawingOn ? 0...slash : (1 - slash)...1
        // Always drawn – the plain symbol sat a bit off from a drawn image (wiggle).
        let timeline = isSlashDrawingOn ? Switch.muting : Switch.unmuting
        let image = Self.icon(base, slash: slash > 0 ? part : nil, dip: Self.dip(switchProgress, timeline))
        image.isTemplate = true
        statusItem?.button?.image = image
    }

    /// The symbol, optionally struck through like SF Symbols' ".slash" variants (none
    /// exists for AudIO's): a diagonal line, cut free from the symbol by a gap – `slash` of
    /// it. `dip` 0…1 fades and shrinks the symbol – away, as the Sound menu's vanishes
    /// between its symbols. Aligned like the symbol itself.
    private static func icon(_ symbol: NSImage, slash part: ClosedRange<CGFloat>?, dip: CGFloat) -> NSImage {
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = 1 - 0.2 * dip
            let scaled = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
            symbol.draw(in: scaled, from: .zero, operation: .sourceOver, fraction: 1 - dip)
            guard let part else { return true }
            let inset = rect.width * 0.08
            let start = CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
            let end = CGPoint(x: rect.maxX - inset, y: rect.minY + inset)
            let point = { (t: CGFloat) in CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t) }
            let segment = [point(part.lowerBound), point(part.upperBound)]
            context.setLineCap(.round)
            context.setBlendMode(.clear)
            context.setLineWidth(rect.width * 0.17)
            context.strokeLineSegments(between: segment)
            context.setBlendMode(.normal)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(rect.width * 0.075)
            context.strokeLineSegments(between: segment)
            return true
        }
        image.alignmentRect = symbol.alignmentRect
        return image
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
        router?.refreshBluetooth() // pairing happens elsewhere, without a device change
        panel.show(below: button)
    }
}

#if compiler(>=6.4) // macOS 27 SDK
@available(macOS 27.0, *)
extension AppDelegate: @MainActor NSStatusItemExpandedInterfaceDelegate {
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
