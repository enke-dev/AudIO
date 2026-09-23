import AudioToolbox
import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let sampleRate: Double
    /// Whether the device exposes a settable hardware volume (HDMI/DP displays often don't).
    let hasVolumeControl: Bool

    var symbolName: String {
        switch transportType {
        case UInt32(kAudioDeviceTransportTypeBuiltIn): "laptopcomputer"
        case UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE): "hifispeaker"
        case UInt32(kAudioDeviceTransportTypeAirPlay): "airplayaudio"
        case UInt32(kAudioDeviceTransportTypeHDMI),
             UInt32(kAudioDeviceTransportTypeDisplayPort): "display"
        case UInt32(kAudioDeviceTransportTypeUSB): "cable.connector"
        case UInt32(kAudioDeviceTransportTypeVirtual): "waveform"
        default: "speaker.wave.2"
        }
    }
}

enum Devices {
    /// UID published by the AudIO HAL driver (Driver/AudIO.c).
    static let virtualDeviceUID = "dev.enke.AudIO.Device"

    /// The AudIO driver's device, when the driver is installed.
    static func virtualDevice() -> SubDevice? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var id = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let uid = virtualDeviceUID as CFString
        let status = withUnsafePointer(to: uid) { qualifier in
            AudioObjectGetPropertyData(
                .system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id
            )
        }
        return status == noErr && id.isValid ? SubDevice(uid: virtualDeviceUID, id: id) : nil
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        try? AudioObjectID.system.write(.init(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    private static let excludedTransports = [
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeAutoAggregate,
    ].map { UInt32($0) }

    static func outputs() -> [OutputDevice] {
        ((try? AudioObjectID.system.readIDs(.init(kAudioHardwarePropertyDevices))) ?? [])
            .compactMap(output(for:))
    }

    static func defaultOutput() -> AudioDeviceID {
        AudioObjectID.system.value(.init(kAudioHardwarePropertyDefaultOutputDevice), default: .unknown)
    }

    static func output(for id: AudioDeviceID) -> OutputDevice? {
        let scope = kAudioObjectPropertyScopeOutput
        let streams = (try? id.readIDs(.init(kAudioDevicePropertyStreams, scope))) ?? []
        let transport = id.value(.init(kAudioDevicePropertyTransportType), default: UInt32(0))
        let isHidden = id.value(.init(kAudioDevicePropertyIsHidden), default: UInt32(0)) != 0

        guard !streams.isEmpty, !isHidden, !excludedTransports.contains(transport),
              let uid = try? id.readString(.init(kAudioDevicePropertyDeviceUID)), !uid.isEmpty,
              uid != virtualDeviceUID
        else { return nil }

        return OutputDevice(
            id: id,
            uid: uid,
            name: (try? id.readString(.init(kAudioObjectPropertyName))) ?? uid,
            transportType: transport,
            sampleRate: id.value(.init(kAudioDevicePropertyNominalSampleRate), default: Float64(0)),
            hasVolumeControl: Volume.isControllable(id)
        )
    }

    /// The HAL process object for a pid, needed to exclude ourselves from the global tap.
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            .system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr ? object : .unknown
    }
}
