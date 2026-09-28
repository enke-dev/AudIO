import AppIntents
import SwiftUI
import WidgetKit

// The outputs widget: AudIO's outputs, ticked on or off with a click – like the panel's
// rows. The app publishes them in its preferences (read here through a read-only sandbox
// exception) and does the toggling itself, asked with a distributed notification.

struct Output: Identifiable, Hashable {
    let uid: String
    let name: String
    let symbol: String
    let isSelected: Bool

    var id: String { uid }
}

enum PublishedOutputs {
    /// The outputs, and whether AudIO routes (controls live) – nil without the app's list.
    static func read() -> (outputs: [Output], isReady: Bool)? {
        guard let list = UserDefaults(suiteName: "dev.enke.AudIO")?.array(forKey: "widgetOutputs") as? [[String: String]]
        else { return nil }
        let outputs = list.compactMap { item -> Output? in
            guard let uid = item["uid"], let name = item["name"] else { return nil }
            return Output(uid: uid, name: name, symbol: item["symbol"] ?? "speaker.wave.2.fill", isSelected: item["selected"] == "1")
        }
        return (outputs, list.first?["ready"] == "1")
    }
}

struct ToggleOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle AudIO Output"

    @Parameter(title: "Output")
    var uid: String

    init() {}

    init(uid: String) {
        self.uid = uid
    }

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            .init("dev.enke.AudIO.toggleOutput"), object: uid, userInfo: nil, deliverImmediately: true
        )
        return .result()
    }
}

struct OutputsEntry: TimelineEntry {
    let date = Date()
    let mute: MuteEntry
    let outputs: [Output]
    let isReady: Bool
    let isAvailable: Bool

    static var now: OutputsEntry {
        let published = PublishedOutputs.read()
        return OutputsEntry(
            mute: .now, outputs: published?.outputs ?? [], isReady: published?.isReady ?? false, isAvailable: published != nil
        )
    }
}

struct OutputsProvider: TimelineProvider {
    func placeholder(in context: Context) -> OutputsEntry {
        OutputsEntry(
            mute: MuteEntry(isMuted: false, volume: 0.5),
            outputs: [
                Output(uid: "a", name: String(localized: "Speaker"), symbol: "hifispeaker.fill", isSelected: true),
                Output(uid: "b", name: String(localized: "Headphones"), symbol: "headphones", isSelected: false),
            ],
            isReady: true, isAvailable: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (OutputsEntry) -> Void) {
        completion(.now)
    }

    /// Reloaded by the app whenever outputs or ticks change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<OutputsEntry>) -> Void) {
        completion(Timeline(entries: [.now], policy: .never))
    }
}

/// Medium: mute and volume on the left, outputs on the right. Large: mute and volume on
/// top, below as many outputs as fit.
struct OutputsWidgetView: View {
    let entry: OutputsEntry
    @Environment(\.widgetFamily) private var family

    /// Five fit the medium size (~128 pt): 5 × 24 + 4 × 2.
    private static let rowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        Group {
            if family == .systemLarge {
                VStack(spacing: 12) {
                    MuteSection(entry: entry.mute).frame(height: 110)
                    list
                }
            } else {
                HStack(spacing: 12) {
                    MuteSection(entry: entry.mute).frame(width: 110)
                    list
                }
            }
        }
        // (Only Apple's own widgets get the glass background – a private flag; third-party ones
        // all sit on the system's dark plate, whatever is set here.)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var list: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                if !entry.isAvailable {
                    Text("Open AudIO once").font(.caption).foregroundStyle(.secondary)
                } else {
                    let hint = entry.isReady ? 0 : 1
                    // As many rows as fit – the hint takes one when AudIO isn't the output.
                    let fitting = Int((geometry.size.height + Self.rowSpacing) / (Self.rowHeight + Self.rowSpacing)) - hint
                    ForEach(entry.outputs.prefix(max(fitting, 0))) { output in
                        Button(intent: ToggleOutputIntent(uid: output.uid)) { row(output) }
                            .buttonStyle(.plain)
                    }
                    if !entry.isReady {
                        Text("Select AudIO as sound output").font(.caption).foregroundStyle(.secondary)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .disabled(!entry.isReady)
    }

    /// Like the panel's rows: a round symbol, accent-colored when ticked.
    private func row(_ output: Output) -> some View {
        HStack(spacing: 8) {
            Image(systemName: output.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(output.isSelected ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(output.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            Text(verbatim: output.name).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .opacity(entry.isReady ? 1 : 0.5)
    }
}

struct OutputsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.enke.AudIO.Outputs", provider: OutputsProvider()) { OutputsWidgetView(entry: $0) }
            .configurationDisplayName("AudIO Outputs")
            .description("Picks the outputs AudIO plays on")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
