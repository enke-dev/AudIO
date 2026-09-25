import CoreAudio
import Foundation

/// Output latency – what an output adds between a sample handed to it and it being heard –
/// and reporting AudIO's total to its driver, so apps (video players) can compensate.
enum Latency {
    /// The driver's custom property ('Alat', frames as CFNumber) – see Driver/AudIO.c.
    static let driverProperty = AudioObjectPropertyAddress(0x416C_6174) // 'Alat'

    /// Device latency + safety offset + IO buffer + stream latency, in seconds. For Bluetooth
    /// outputs the device latency carries the (large) radio/codec delay.
    static func output(of device: AudioDeviceID) -> Double {
        let scope = kAudioObjectPropertyScopeOutput
        let frames = [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize]
            .map { device.value(.init($0, scope), default: UInt32(0)) }
            .reduce(0, +)
        let stream = (try? device.readIDs(.init(kAudioDevicePropertyStreams, scope)))?.first
            .map { $0.value(.init(kAudioStreamPropertyLatency), default: UInt32(0)) } ?? 0
        return Double(frames + stream) / sampleRate(of: device)
    }

    /// Reports `seconds` as the driver's latency (in its current sample rate's frames).
    static func report(_ seconds: Double, to driver: AudioDeviceID) {
        let frames = Int32(max(0, seconds * sampleRate(of: driver)).rounded())
        var value: CFPropertyList = NSNumber(value: frames)
        var address = driverProperty
        _ = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(driver, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), pointer)
        }
    }

    private static func sampleRate(of device: AudioDeviceID) -> Double {
        let rate = device.value(.init(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
        return rate > 0 ? rate : 48_000
    }
}
