import CoreAudio
import Foundation

struct SubDevice: Hashable {
    let uid: String
    let id: AudioDeviceID
}

/// Buffer indices of each sub-device's streams in the aggregate's IOProc buffer lists.
struct StreamLayout {
    var outputs: [String: Range<Int>] = [:]
    var inputs: [String: Range<Int>] = [:]
    var outputCount = 0
    var inputCount = 0
}

/// Private aggregate devices: invisible to other apps, destroyed with our process.
enum Aggregate {
    /// The clock device drives the aggregate; every other sub-device (and the tap) is
    /// drift-compensated.
    static func create(
        name: String,
        subDevices: [SubDevice],
        clockUID: String,
        tapUUID: UUID? = nil
    ) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "dev.enke.AudIO.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices.map { device -> [String: Any] in
                [
                    kAudioSubDeviceUIDKey: device.uid,
                    kAudioSubDeviceDriftCompensationKey: device.uid == clockUID ? 0 : 1,
                ]
            },
        ]
        if let tapUUID {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ] as [String: Any],
            ]
        }
        var id = AudioObjectID.unknown
        try AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
            .check("Creating the device group")
        return id
    }

    static func destroy(_ id: AudioObjectID) {
        if id.isValid { _ = AudioHardwareDestroyAggregateDevice(id) }
    }

    static func sampleRate(of id: AudioObjectID, fallback: Double) -> Double {
        let rate = id.value(.init(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
        return rate > 0 ? rate : fallback
    }

    /// Buffers are the sub-devices' streams concatenated in active sub-device order;
    /// tap streams follow after all sub-device input streams.
    static func layout(of aggregate: AudioObjectID, subDevices: [SubDevice]) -> StreamLayout {
        let byUID = Dictionary(subDevices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let active = ((try? aggregate.readIDs(.init(kAudioAggregateDevicePropertyActiveSubDeviceList))) ?? [])
            .compactMap { try? $0.readString(.init(kAudioDevicePropertyDeviceUID)) }
            .filter { byUID[$0] != nil }
        let order = active.isEmpty ? subDevices.map(\.uid) : active

        return order.reduce(into: StreamLayout()) { layout, uid in
            guard let device = byUID[uid] else { return }
            let outputs = device.id.streamCount(kAudioObjectPropertyScopeOutput)
            let inputs = device.id.streamCount(kAudioObjectPropertyScopeInput)
            layout.outputs[uid] = layout.outputCount..<(layout.outputCount + outputs)
            layout.inputs[uid] = layout.inputCount..<(layout.inputCount + inputs)
            layout.outputCount += outputs
            layout.inputCount += inputs
        }
    }
}
