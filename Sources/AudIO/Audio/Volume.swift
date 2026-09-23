import AudioToolbox
import CoreAudio
import Foundation

/// Hardware volume through the same "virtual main volume" (0…1) the Sound settings use,
/// so changes show up there, in Audio MIDI Setup and on Bluetooth speakers themselves.
enum Volume {
    static let main = AudioObjectPropertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput
    )
    static let mute = AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    static func isControllable(_ id: AudioDeviceID) -> Bool {
        id.has(main) && id.isSettable(main)
    }

    static func read(_ id: AudioDeviceID) -> Double? {
        guard id.has(main), let value = try? id.read(main, initial: Float32(0)) else { return nil }
        return Double(value)
    }

    static func write(_ value: Double, to id: AudioDeviceID) {
        try? id.write(main, Float32(value.clamped01))
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        id.has(mute) && id.value(mute, default: UInt32(0)) != 0
    }

    /// Perceptual curve for devices without hardware volume (~60 dB range, like a fader).
    static func gain(for scalar: Double) -> Float {
        Float(pow(scalar.clamped01, 3))
    }
}

extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
