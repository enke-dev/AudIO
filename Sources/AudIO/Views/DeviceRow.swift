import SwiftUI

/// One output, like the rows of the Sound menu: a round symbol that turns accent-colored
/// when selected, the whole row clickable with a hover highlight. Looks the device up by
/// UID, so a reconnected device (new ID) keeps its row.
struct DeviceRow: View {
    let uid: String
    @EnvironmentObject private var router: Router

    var body: some View {
        if let device = router.devices.first(where: { $0.uid == uid }) {
            let settings = router.binding(for: uid)
            let isSelected = settings.wrappedValue.isSelected
            Button {
                // Animated: level/delay slide open while the panel grows along.
                withAnimation(MenuMetrics.animation) { settings.wrappedValue.isSelected.toggle() }
            } label: {
                HStack(spacing: MenuMetrics.iconSpacing) {
                    Image(systemName: device.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
                        .background(Circle().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                    Text(verbatim: device.name).font(.body).lineLimit(1)
                    if showsID(device) {
                        Text(verbatim: "#\(device.id)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: MenuMetrics.rowHeight)
                .menuRowHighlight(isEnabled: router.isReady)
            }
            .buttonStyle(.plain)
            .help(device.uid)
            .disabled(!router.isReady)
        }
    }

    /// Names shared by several devices (e.g. two identical displays) get their ID shown.
    private func showsID(_ device: OutputDevice) -> Bool {
        router.devices.filter { $0.name == device.name }.count > 1
    }
}

/// Level and delay of a selected output, below its row: symbol and slider aligned with the
/// master volume's, then value and label ("240 ms Delay") – on a
/// lighter band spanning the panel's full width, like the Sound menu's expanded AirPods
/// section (measured: ~10 % white over the glass in dark mode).
struct DeviceDetail: View {
    let uid: String
    @EnvironmentObject private var router: Router

    /// The band's own padding, and its distance to the rows above and below (Sound menu:
    /// 5 pt each, measured).
    private static let padding: CGFloat = 5
    /// Fixed, so it can be revealed by animating its frame: gap, band (padding, two rows with
    /// spacing, padding), gap.
    static let height: CGFloat = padding + (padding + 22 + 2 + 22 + padding) + padding

    var body: some View {
        let settings = router.binding(for: uid)
        // A grid: the sliders take all the width the values and the longest (translated)
        // label leave, and stay equally long.
        Grid(alignment: .leading, horizontalSpacing: MenuMetrics.sliderSpacing, verticalSpacing: 2) {
            ParameterRow(title: "Level", symbol: "speaker.wave.2", value: router.volumeBinding(for: uid), range: 0...1, step: 0.01) {
                "\(Int(($0 * 100).rounded())) %"
            }
            ParameterRow(title: "Delay", symbol: "timer", value: settings.delayMs, range: 0...500, step: 1) {
                "\(Int($0.rounded())) ms"
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, MenuMetrics.inset)
        .padding(.trailing, MenuMetrics.inset)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.1))
        .padding(.vertical, Self.padding)
        .frame(height: Self.height, alignment: .top)
        .disabled(!router.isReady)
    }
}

private struct ParameterRow: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        GridRow {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: MenuMetrics.sliderIconWidth)
            // (row height set on a cell – a modifier on the GridRow itself would turn it into
            // a single cell spanning the grid)
            MenuSlider(value: $value, range: range, step: step, knob: CGSize(width: 20, height: 14), track: 4)
                .frame(height: 22)
            // Value and label read as one ("240 ms Delay"). The value reserves the width of
            // its largest value ("500 ms", monospaced digits) – the sliders keep their length
            // while dragging, and at full digit count the gap equals the one on the left.
            HStack(spacing: 3) {
                ZStack(alignment: .trailing) {
                    Text(verbatim: display(range.upperBound)).hidden()
                    Text(verbatim: display(value))
                }
                .monospacedDigit()
                Text(title).lineLimit(1)
            }
        }
    }
}
