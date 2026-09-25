import AppKit
import SwiftUI

// Control Center's own controls (Sound / Wi-Fi / Battery menus) are private – neither
// SwiftUI nor AppKit expose them, and SwiftUI's `Slider` renders as a regular NSSlider.
// These few building blocks recreate them, with metrics measured from the Sound menu
// (macOS 26, 1× screenshot). Fonts, colors and separators use the system's semantic
// styles (`.headline`, `.secondary`, `.quaternary`, `Divider`), so they follow the OS.

enum MenuMetrics {
    static let width: CGFloat = 320
    static let panelRadius: CGFloat = 16
    /// Content (title, icons, labels, separators) from the menu edge.
    static let inset: CGFloat = 14
    /// Hover highlight (and error pill) from the menu edge.
    static let highlightInset: CGFloat = 5
    /// Concentric with the panel's corners (Sound menu: 10, measured).
    static let highlightRadius = panelRadius - highlightInset
    /// Panel edge → title row (panel padding + the title's own).
    static let titleTop: CGFloat = 6 + 6
    static let rowHeight: CGFloat = 32
    static let actionHeight: CGFloat = 22
    static let iconSize: CGFloat = 26
    /// Symbol circle → label.
    static let iconSpacing: CGFloat = 8
    /// Where labels start (and where level/delay line up).
    static let textInset = inset + iconSize + iconSpacing
    /// Symbol column left of a slider (master, level, delay) – fixed, so all sliders start
    /// at the same x, whatever the symbol. With the spacing, like the Sound menu (macOS 27,
    /// measured): the speaker 2.5 pt in, the slider 20 pt in, 8.5 pt after the speaker.
    static let sliderIconWidth: CGFloat = 14
    /// Symbol → slider.
    static let sliderSpacing: CGFloat = 6
    /// Level/delay opening – the panel grows along in the same SwiftUI animation.
    static let animation = Animation.easeInOut(duration: 0.25)
}

/// Hover highlight of a clickable row, like the Sound menu's.
private struct RowHighlight: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MenuMetrics.inset - MenuMetrics.highlightInset)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.highlightRadius, style: .continuous)
                    .fill(isHovered && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .onHover { isHovered = $0 }
            .padding(.horizontal, MenuMetrics.highlightInset)
    }
}

extension View {
    func menuRowHighlight(isEnabled: Bool = true) -> some View {
        modifier(RowHighlight(isEnabled: isEnabled))
    }
}

/// The system separator, inset to align with the content.
struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.vertical, 5)
    }
}

struct MenuSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.horizontal, MenuMetrics.inset)
    }
}

/// Control Center style slider: thin track, accent fill, flattened white knob.
struct MenuSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var knob = CGSize(width: 20, height: 16)
    var track: CGFloat = 6

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let span = range.upperBound - range.lowerBound
            let usable = max(geometry.size.width - knob.width, 1)
            let offset = usable * CGFloat(((value - range.lowerBound) / span).clamped01)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: track)
                Capsule().fill(Color.accentColor).frame(width: offset + knob.width / 2, height: track)
                Capsule()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: knob.width, height: knob.height)
                    .offset(x: offset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = Double((drag.location.x - knob.width / 2) / usable).clamped01
                    let raw = range.lowerBound + fraction * span
                    value = step.map { (raw / $0).rounded() * $0 } ?? raw
                }
            )
        }
        .frame(height: knob.height)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A plain menu action ("Toneinstellungen …" style), flush with the content.
struct MenuActionRow: View {
    let title: LocalizedStringKey
    /// Replaces `title` with an already localized text (e.g. a running action's progress).
    var verbatimTitle: String?
    var shortcut: String?
    var isChecked = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        // Enabled/disabled only changes opacity and whether the action runs – the view's
        // structure and style stay the same. Swapping styles (or `.disabled`) mid-animation
        // made SwiftUI crossfade the row, with the new copy jumping ahead of the others.
        Button {
            if isEnabled { action() }
        } label: {
            HStack {
                Group {
                    if let verbatimTitle { Text(verbatim: verbatimTitle) } else { Text(title) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                }
                if let shortcut {
                    Text(verbatim: shortcut).foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .opacity(isEnabled ? 1 : 0.3)
            .frame(height: MenuMetrics.actionHeight)
            .menuRowHighlight(isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isEnabled ? [] : .isStaticText)
    }
}

/// "AudIO" title, plus a button only for what's missing (install/update the driver, select
/// AudIO) or an app update.
struct MenuTitleView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var updater: Updater

    var body: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: "AudIO").font(.headline)
                Text(verbatim: Self.version).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            // Selecting "AudIO" as sound output is the switch; buttons only for what's missing.
            if router.isInstallingDriver || router.measuringText != nil || updater.state == .updating {
                // Label first, spinner last – always in the top-right corner.
                HStack(spacing: 6) {
                    Group {
                        if router.isInstallingDriver {
                            Text("Installing…")
                        } else if router.measuringText != nil {
                            Text("Measuring…")
                        } else {
                            Text("Updating…")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
            } else if let title = driverButtonTitle {
                Pill(text: Text(title), style: .filled, action: router.installDriver)
                    .disabled(router.driverState == .unavailable)
                    .inCorner()
                    .help("Adds “AudIO” as a sound output – asks for your password")
            } else if router.driver != nil, !router.isDriverActive {
                Pill(text: Text("Use AudIO"), style: .filled, action: router.activate)
                    .inCorner()
                    .help("Selects “AudIO” as sound output – same as picking it in the Sound menu")
            } else if case .available(let version) = updater.state {
                Pill(text: Text("Update to \(version)"), style: .filled, action: updater.install)
                    .inCorner()
                    .help("Downloads AudIO \(version) from GitHub, replaces this version and restarts")
            } else if case .failed(let message) = updater.state {
                Pill(text: Text("Update Failed"), tint: .red, style: .filled, action: updater.retry)
                    .inCorner()
                    .help("\(message) Click to try again.")
            }
        }
        .frame(height: 22)
        .padding(.horizontal, MenuMetrics.inset)
        .padding(.top, 6)
    }

    /// The app's version – "dev" for local builds (CI stamps the real one).
    private static let version: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.flatMap { $0 == "0.0.0" ? nil : $0 } ?? "dev"
    }()

    private var driverButtonTitle: LocalizedStringKey? {
        switch router.driverState {
        case .notInstalled, .unavailable: router.driver == nil ? "Install Audio Device" : nil
        case .outdated: "Update Audio Device"
        case .current: nil
        }
    }
}

/// Errors and a slow start, below the title. An action's error is a pill with a close
/// button that also goes away by itself after a while (not while pointed at).
struct MenuNoticeView: View {
    let notice: Router.Notice
    var dismiss: (() -> Void)?
    var hold: ((Bool) -> Void)?

    var body: some View {
        Group {
            if notice.isDismissible {
                Pill(text: Text(verbatim: notice.text), tint: .red, close: { dismiss?() }, hold: hold)
                    // Like a row highlight: from the panel edge, concentric with its corners.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MenuMetrics.highlightInset)
            } else {
                Text(verbatim: notice.text)
                    .font(.caption)
                    .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MenuMetrics.inset)
            }
        }
        .padding(.bottom, 2)
    }
}

/// The panel's pill – a message (tinted, may wrap, optionally closable) or a button
/// (filled, for what's missing: install, select AudIO, an update – it must stand out,
/// often among disabled controls). One line makes a pill, more a rectangle with the same
/// rounding: that of the row highlights. Text aligned with the content.
struct Pill: View {
    enum Style {
        /// Tint on a light tint fill.
        case tinted
        /// White on the tint.
        case filled
    }

    let text: Text
    var tint: Color = .accentColor
    var style: Style = .tinted
    /// Makes it a button – brighter while pointed at.
    var action: (() -> Void)?
    /// A close button top right, also when the text wraps.
    var close: (() -> Void)?
    /// Pointed at or not – e.g. to keep it while being read.
    var hold: ((Bool) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { pill.contentShape(PillShape()) }
                .buttonStyle(.plain)
                .compositingGroup()
                .opacity(isEnabled ? 1 : 0.4)
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(alignment: .top, spacing: 6) {
            text
                .font(action == nil ? .caption : .caption.weight(.medium))
                .foregroundStyle(style == .filled ? .white : tint)
                .fixedSize(horizontal: false, vertical: true)
            if let close { PillCloseButton(tint: tint, action: close) }
        }
        // Buttons stay on one line; a close button's center sits one corner radius from the
        // top and trailing edge – its hover circle concentric with the rounding.
        .lineLimit(action == nil ? nil : 1)
        .padding(.leading, MenuMetrics.inset - MenuMetrics.highlightInset)
        .padding(.trailing, close == nil ? MenuMetrics.inset - MenuMetrics.highlightInset : PillShape.radius - PillCloseButton.size / 2)
        .padding(.vertical, PillShape.radius - PillCloseButton.size / 2)
        .frame(minHeight: PillShape.radius * 2)
        .background(PillShape().fill(style == .filled ? tint : tint.opacity(0.15)))
        .brightness(action != nil && isHovered && isEnabled ? 0.08 : 0)
        .onHover { hovering in
            isHovered = hovering
            hold?(hovering)
        }
    }
}

/// A pill on one line (as high as the close button plus its padding); on more, a
/// rectangle with the same corner rounding – that of the row highlights.
private struct PillShape: Shape {
    static let radius = MenuMetrics.highlightRadius

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.height / 2, Self.radius), style: .continuous)
    }
}

extension View {
    /// A title-row pill moved into the panel's top-right corner: as far from the top as
    /// from the side, concentric with the panel's rounding (a pill's radius is the
    /// highlights'). Only drawn there – the title row keeps its layout.
    func inCorner() -> some View {
        offset(
            x: MenuMetrics.inset - MenuMetrics.highlightInset,
            y: MenuMetrics.highlightInset - MenuMetrics.titleTop
        )
    }
}

/// The pill's close button: a round background while pointed at.
private struct PillCloseButton: View {
    static let size: CGFloat = 14
    /// The hover circle's gap to the pill's edge, all around.
    private static let gap: CGFloat = 3
    /// Concentric with the pill's rounding – drawn beyond the button's frame, into the
    /// pill's padding, so a single line stays a pill.
    private static let outset = PillShape.radius - gap - size / 2

    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(tint.opacity(isHovered ? 0.2 : 0)).padding(-Self.outset))
                .contentShape(Circle().inset(by: -Self.outset))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .onHover { isHovered = $0 }
        .help("Close")
    }
}

/// AudIO's own volume – the master; the volume keys and the Sound menu control it too.
struct MasterVolumeView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack(spacing: MenuMetrics.sliderSpacing) {
            Image(systemName: router.isDriverMuted ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: MenuMetrics.sliderIconWidth)
            MenuSlider(value: router.driverVolumeBinding())
            // The symbol's own space on its left: 7 pt to the slider, as in the Sound menu.
            Image(systemName: "speaker.wave.3.fill").padding(.leading, -1.5)
        }
        // Like the Sound menu's (measured): 16 pt, brighter than `.secondary`.
        .font(.system(size: 16))
        .foregroundStyle(Color.primary.opacity(0.55))
        .frame(height: 26)
        .padding(.horizontal, MenuMetrics.inset)
        .disabled(!router.isReady)
    }
}

/// "Measure Delays", "Check for Updates" and "Open at Login".
struct MenuActionsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var updater: Updater
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            // The panel stays open: the running measurement shows in place of the title.
            MenuActionRow(
                title: "Measure Delays", verbatimTitle: router.measuringText,
                isEnabled: router.isReady && router.canMeasure
            ) {
                router.measureDelays()
            }
            .help("Plays a short test tone on each selected output and measures when it arrives")
            // Locked with the other controls – the checks themselves run regardless, and an
            // available update still shows in the title.
            MenuActionRow(title: "Check for Updates", isChecked: updater.isEnabled, isEnabled: router.isReady) {
                updater.isEnabled.toggle()
            }
            .help("Looks for a new release on GitHub at launch and once a day")
            MenuActionRow(title: "Open at Login", isChecked: launchAtLogin, isEnabled: router.isReady && LaunchAtLogin.isAvailable) {
                LaunchAtLogin.set(!launchAtLogin)
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

struct MenuQuitRow: View {
    var body: some View {
        MenuActionRow(title: "Quit AudIO", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
