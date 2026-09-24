import AppKit
import OSLog
import SwiftUI

let panelLog = Logger(subsystem: "dev.enke.AudIO", category: "panel")

/// Borderless panel below the status item, like the Sound and Control Center menus.
///
/// The window itself never resizes: it is a fixed, transparent (click-through) area below
/// the icon, and SwiftUI draws the visible panel inside it – system material included
/// (Liquid Glass via `glassEffect` on macOS 26+, the menu material before). Content and
/// panel therefore animate in one pass; resizing the window alongside a SwiftUI animation
/// makes the two fight each other.
final class MenuPanel: NSPanel {
    static let cornerRadius: CGFloat = 16
    /// Distance to the screen edges; the top sits flush below the icon like system menus.
    private static let screenMargin: CGFloat = 5
    /// Transparent room left/right of the surface for its shadow.
    static let sideMargin: CGFloat = 20

    private let hosting: NSHostingView<AnyView>
    private let metrics = SurfaceMetrics()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var visibilityObserver: NSObjectProtocol?
    private var shownAt = Date.distantPast
    private weak var anchor: NSStatusBarButton?
    /// When the panel last closed – a click on the status item that closed it (by taking
    /// focus) must not immediately reopen it.
    private(set) var lastDismissal = Date.distantPast
    /// Whether the panel lights the status item itself (the system does it on macOS 27+).
    var managesHighlight = true
    /// Asked first when the panel should close (Escape, click elsewhere, an action). Returns
    /// true if the owner closes it – on macOS 27 the status item's session does: it's
    /// cancelled and the system then asks to `hide()` the panel.
    var requestClose: (() -> Bool)?

    init<Content: View>(rootView: Content) {
        hosting = NSHostingView(rootView: AnyView(PanelSurface(content: rootView, metrics: metrics)))
        hosting.sizingOptions = [] // the window has a fixed size – never let content resize it
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the surface draws its own
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Like the system menus: opens on the current space (full-screen ones included) and
        // is transient – Mission Control and space switches don't carry it along.
        collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
        contentView = hosting
    }

    // Borderless windows can't become key by default – sliders, ⌘Q and Escape need it.
    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        if managesHighlight { anchor?.highlight(true) }
    }

    override func resignKey() {
        super.resignKey()
        dismiss() // clicked elsewhere, switched apps, a system prompt appeared …
    }

    /// Clicks that reach the window outside the visible surface count as "outside".
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            let height = metrics.height
            let surface = NSRect(
                x: Self.sideMargin,
                y: frame.height - height,
                width: MenuMetrics.width,
                height: height
            )
            if !surface.contains(event.locationInWindow) { return dismiss() }
        }
        super.sendEvent(event)
    }

    func show(below button: NSStatusBarButton) {
        anchor = button
        place(below: button)
        // Non-activating: the panel becomes key without AudIO taking focus from the frontmost
        // app (redrawing the status bar would drop the highlight before macOS 27).
        makeKeyAndOrderFront(nil)
        shownAt = Date()
        panelLog.notice("show (active: \(NSApp.isActive, privacy: .public), space: \(self.isOnActiveSpace, privacy: .public))")
        if managesHighlight {
            button.highlight(true)
            DispatchQueue.main.async { [weak self, weak button] in
                MainActor.assumeIsolated {
                    guard self?.isVisible == true else { return }
                    button?.highlight(true)
                }
            }
        }

        let clickElsewhere = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }
        monitors = [clickElsewhere, escape].compactMap { $0 }

        // Mission Control, space switches, sleep: close like the system menus do – an open
        // session across those left the menu bar stuck (shown in full screen, no hover reveal).
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    panelLog.notice("closing: \(note.name.rawValue, privacy: .public)")
                    self?.dismiss()
                }
            }
        }
        // Mission Control has no notification – it hides transient windows, so check for that.
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // (ignoring the moment it appears, before it counts as visible)
                guard let self, self.isVisible, !self.occlusionState.contains(.visible),
                      Date().timeIntervalSince(self.shownAt) > 0.3 else { return }
                panelLog.notice("closing: occluded (Mission Control?)")
                self.dismiss()
            }
        }
    }

    /// Closes the panel – through the owner (`requestClose`) if it manages that.
    func dismiss() {
        guard isVisible else { return }
        if requestClose?() == true {
            // Fallback if the system never reports the session's end.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    panelLog.error("session end not reported – hiding")
                    self.hide()
                }
            }
            return
        }
        hide()
    }

    /// Takes the panel off screen.
    func hide() {
        guard isVisible else { return }
        panelLog.notice("hide (active: \(NSApp.isActive, privacy: .public))")
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        visibilityObserver.map(NotificationCenter.default.removeObserver)
        visibilityObserver = nil
        if managesHighlight { anchor?.highlight(false) }
        lastDismissal = Date()
        orderOut(nil)
        // AudIO can still end up active (the macOS 27 session, a click into the panel). Hand
        // focus back like the system menus do – an accessory
        // app left active over a full-screen app keeps that space's menu bar revealed.
        if NSApp.isActive { NSApp.deactivate() }
    }

    /// A fixed area from just below the icon down to the bottom of the screen.
    private func place(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let item = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = MenuMetrics.width + Self.sideMargin * 2

        // Surface left-aligned with the icon's highlight pill like the system menus, but kept
        // on screen. The pill spans the whole status item window; the button inside is narrower.
        let surfaceX = min(
            max(buttonWindow.frame.minX, screen.minX + Self.screenMargin),
            screen.maxX - MenuMetrics.width - Self.screenMargin
        )
        let top = item.minY
        setFrame(
            NSRect(x: surfaceX - Self.sideMargin, y: screen.minY, width: width, height: top - screen.minY),
            display: true
        )
    }
}

/// The visible surface's current height, reported by SwiftUI (for hit-testing).
private final class SurfaceMetrics {
    var height: CGFloat = 0
}

/// The panel as SwiftUI draws it: content on the system material, rounded, pinned to the top
/// of the transparent window.
private struct PanelSurface<Content: View>: View {
    let content: Content
    let metrics: SurfaceMetrics

    var body: some View {
        VStack(spacing: 0) {
            content
                .modifier(PanelMaterial())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metrics.height = $0 }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MenuPanel.sideMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Liquid Glass on macOS 26+, the menu material before – both from the system.
private struct PanelMaterial: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MenuPanel.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        // The glass' own shadow is far wider than the system menus' (and gets cut at the
        // window edge) – clip it off and add a small, soft one like theirs. The clip sits a
        // little outside the edge: the glass rim straddles it and must stay intact.
        if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .clipShape(OutsetRoundedRectangle(cornerRadius: MenuPanel.cornerRadius, outset: 2))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        } else {
            content
                .background(MenuMaterial())
                .clipShape(shape)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        }
    }
}

private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A rounded rectangle drawn `outset` points outside the view's bounds (same corner curve).
private struct OutsetRoundedRectangle: Shape {
    let cornerRadius: CGFloat
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
            .path(in: rect.insetBy(dx: -outset, dy: -outset))
    }
}
