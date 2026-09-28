import AppIntents
import AudioToolbox
import CoreAudio
import SwiftUI
import WidgetKit

// The widget extension: AudIO's volume and mute as a desktop widget. It reads them and sets
// the mute on the AudIO device itself (Core Audio) – no data shared with the app needed; the
// app only asks WidgetKit to reload when they change elsewhere.

/// The AudIO device's mute and volume (see Driver/AudIO.c).
enum AudIOMute {
    private static let deviceUID = "dev.enke.AudIO.Device"
    private static var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
    )
    /// The same "virtual main volume" (0…1) the app and the Sound settings use.
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static var volume: Double? {
        guard let device else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr ? Double(volume) : nil
    }

    /// nil: the device isn't there (driver not installed).
    static var isMuted: Bool? {
        guard let device else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr ? muted != 0 : nil
    }

    static func set(_ muted: Bool) {
        guard let device else { return }
        var value = UInt32(muted ? 1 : 0)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static var device: AudioObjectID? {
        var translate = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var uid = deviceUID as CFString
        let status = withUnsafePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id
            )
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute AudIO"

    func perform() async throws -> some IntentResult {
        AudIOMute.isMuted.map { AudIOMute.set(!$0) }
        return .result()
    }
}

struct MuteEntry: TimelineEntry {
    let date = Date()
    let isMuted: Bool?
    let volume: Double

    static var now: MuteEntry { MuteEntry(isMuted: AudIOMute.isMuted, volume: AudIOMute.volume ?? 0) }
}

struct MuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> MuteEntry { MuteEntry(isMuted: false, volume: 0.5) }

    func getSnapshot(in context: Context, completion: @escaping (MuteEntry) -> Void) {
        completion(.now)
    }

    /// Reloaded by the app (and after the button) – nothing to schedule.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MuteEntry>) -> Void) {
        completion(Timeline(entries: [.now], policy: .never))
    }
}

struct MuteWidgetView: View {
    let entry: MuteEntry

    var body: some View {
        MuteSection(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Mute button and volume – the small widget, and the left of the outputs widget.
struct MuteSection: View {
    let entry: MuteEntry

    var body: some View {
        Button(intent: ToggleMuteIntent()) {
            VStack(spacing: 8) {
                Image(systemName: entry.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 30, weight: .medium))
                    .frame(height: 36)
                Text(verbatim: "AudIO").font(.headline)
                if entry.isMuted == nil {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                } else {
                    // Muted reads 0, like the panel's slider.
                    VolumeBar(value: entry.isMuted == true ? 0 : entry.volume)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(entry.isMuted == nil)
    }
}

/// The volume as a level – no knob, no accent: it reads as a display, not a control (the
/// widget can't be dragged), without looking disabled.
struct VolumeBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.2))
                Capsule().fill(.primary).frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 8)
    }
}

struct MuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.enke.AudIO.Mute", provider: MuteProvider()) { MuteWidgetView(entry: $0) }
            .configurationDisplayName("AudIO")
            .description("Mutes AudIO")
            .supportedFamilies([.systemSmall])
    }
}

@main
struct AudIOWidgets: WidgetBundle {
    var body: some Widget {
        MuteWidget()
        OutputsWidget()
    }
}
