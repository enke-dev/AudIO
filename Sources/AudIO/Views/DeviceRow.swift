import SwiftUI

struct DeviceRow: View {
    let device: OutputDevice
    let isSystemOutput: Bool
    let showsID: Bool
    @Binding var settings: RouteSettings
    @Binding var volume: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $settings.isSelected) {
                HStack(spacing: 6) {
                    Image(systemName: device.symbolName).frame(width: 18)
                    Text(device.name).lineLimit(1)
                    if showsID {
                        Text("#\(device.id)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if isSystemOutput {
                        Text("System")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .toggleStyle(.checkbox)
            .help(device.uid)

            if settings.isSelected {
                ParameterRow(title: "Level", value: $volume, range: 0...1, step: 0.01) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                ParameterRow(title: "Delay", value: $settings.delayMs, range: 0...500, step: 1) {
                    "\(Int($0.rounded())) ms"
                }
            }
        }
    }
}

private struct ParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
            // No `step:` here – on macOS it draws a tick mark per step. Snap in the binding instead.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .controlSize(.small)
            Text(display(value))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
        .padding(.leading, 24)
    }
}
