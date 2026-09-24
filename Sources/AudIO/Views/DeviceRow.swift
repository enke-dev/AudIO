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

/// Level and delay of a selected output, below its row, aligned with the device name.
struct DeviceDetail: View {
    let uid: String
    @EnvironmentObject private var router: Router

    /// Fixed, so it can be revealed by animating its frame (two rows + spacing + bottom).
    static let height: CGFloat = 22 + 2 + 22 + 6

    var body: some View {
        let settings = router.binding(for: uid)
        // A grid, so the sliders line up after the longest label – in any language.
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            ParameterRow(title: "Level", value: router.volumeBinding(for: uid), range: 0...1, step: 0.01) {
                "\(Int(($0 * 100).rounded())) %"
            }
            ParameterRow(title: "Delay", value: settings.delayMs, range: 0...500, step: 1) {
                "\(Int($0.rounded())) ms"
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, MenuMetrics.textInset)
        .padding(.trailing, MenuMetrics.inset)
        .padding(.bottom, 6)
        .frame(height: Self.height, alignment: .top)
        .disabled(!router.isReady)
    }
}

private struct ParameterRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        GridRow {
            Text(title).lineLimit(1)
            // (row height set on a cell – a modifier on the GridRow itself would turn it into
            // a single cell spanning the grid)
            MenuSlider(value: $value, range: range, step: step, knob: CGSize(width: 20, height: 14), track: 4)
                .frame(height: 22)
            Text(verbatim: display(value))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}
