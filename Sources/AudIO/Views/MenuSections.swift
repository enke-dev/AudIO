import AppKit
import SwiftUI

// Control Center's own controls (Sound / Wi-Fi / Battery menus) are private – neither
// SwiftUI nor AppKit expose them, and SwiftUI's `Slider` renders as a regular NSSlider.
// These few building blocks recreate them, with metrics measured from the Sound menu
// (macOS 26, 1× screenshot). Fonts, colors and separators use the system's semantic
// styles (`.headline`, `.secondary`, `.quaternary`, `Divider`), so they follow the OS.

enum MenuMetrics {
    static let width: CGFloat = 320
    /// Content (title, icons, labels, separators) from the menu edge.
    static let inset: CGFloat = 14
    /// Hover highlight from the menu edge.
    static let highlightInset: CGFloat = 5
    static let rowHeight: CGFloat = 32
    static let actionHeight: CGFloat = 22
    static let iconSize: CGFloat = 26
    /// Symbol circle → label.
    static let iconSpacing: CGFloat = 8
    /// Where labels start (and where level/delay line up).
    static let textInset = inset + iconSize + iconSpacing
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
    let title: String

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
    let title: String
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
                Text(title)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                }
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
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
                Text("AudIO").font(.headline)
                Text(Self.version).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            // Selecting "AudIO" as sound output is the switch; buttons only for what's missing.
            if router.isInstallingDriver || updater.state == .updating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(router.isInstallingDriver ? "Installing…" : "Updating…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let title = driverButtonTitle {
                Button(title) { router.installDriver() }
                    .controlSize(.small)
                    .disabled(router.driverState == .unavailable)
                    .help("Adds “AudIO” as a sound output – asks for your password")
            } else if router.driver != nil, !router.isDriverActive {
                Button("Use AudIO") { router.activate() }
                    .controlSize(.small)
                    .help("Selects “AudIO” as sound output – same as picking it in the Sound menu")
            } else if case .available(let version) = updater.state {
                Button("Update to \(version)") { updater.install() }
                    .controlSize(.small)
                    .help("Downloads AudIO \(version) from GitHub, replaces this version and restarts")
            } else if case .failed(let message) = updater.state {
                Button("Update Failed") { updater.retry() }
                    .controlSize(.small)
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

    private var driverButtonTitle: String? {
        switch router.driverState {
        case .notInstalled, .unavailable: router.driver == nil ? "Install Audio Device" : nil
        case .outdated: "Update Audio Device"
        case .current: nil
        }
    }
}

/// Errors and a running measurement, below the title.
struct MenuNoticeView: View {
    let notice: Router.Notice

    var body: some View {
        Text(notice.text)
            .font(.caption)
            .foregroundStyle(notice.isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.inset)
            .padding(.bottom, 2)
    }
}

/// AudIO's own volume – the master; the volume keys and the Sound menu control it too.
struct MasterVolumeView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: router.isDriverMuted ? "speaker.slash.fill" : "speaker.fill")
            MenuSlider(value: router.driverVolumeBinding())
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .frame(height: 26)
        .padding(.horizontal, MenuMetrics.inset)
        .disabled(!router.isReady)
    }
}

/// "Measure Delays", "Check for Updates" and "Open at Login".
struct MenuActionsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var updater: Updater
    /// Closes the panel before an action that takes over (the measurement).
    var close: () -> Void = {}
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            MenuActionRow(title: "Measure Delays", isEnabled: router.isReady && router.canMeasure) {
                close()
                router.measureDelays()
            }
            .help("Plays a short test tone on each selected output and measures when it arrives")
            MenuActionRow(title: "Check for Updates", isChecked: updater.isEnabled) {
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
