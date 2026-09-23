import CoreAudio
import Foundation
import os

/// Owns the process tap, the private aggregate device and its IOProc.
///
/// Layout: a stereo tap of everything apps play into the AudIO device (a silent sink) is
/// added to a private aggregate made of the selected outputs. The clock device drives the
/// aggregate, every other sub-device and the tap get drift compensation.
///
/// Thread confinement instead of locks: `start`/`stop` only run on the router's serial
/// engine queue; `routes`/`probe` are read elsewhere only while no start/stop is pending.
final class Engine: @unchecked Sendable {
    private(set) var routes: [Route] = []
    /// Test-tone injector for in-session delay measurement.
    private(set) var probe: Probe?

    /// Called on the main queue when the aggregate needs to be rebuilt (e.g. sample-rate change).
    var onConfigurationLost: (() -> Void)?

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var listeners: [PropertyListener] = []
    private let log = Logger(subsystem: "dev.enke.AudIO", category: "engine")

    deinit { stop() }

    /// - Parameters:
    ///   - outputs: devices that play the captured audio (may be empty = silence).
    ///   - clock: clock device; always part of the aggregate, routed only if in `outputs`.
    ///   - source: UID of the device whose output is tapped (the AudIO sink).
    func start(outputs: [OutputDevice], clock: OutputDevice, source: String) throws {
        stop()
        do {
            try build(outputs: outputs, clock: clock, source: source)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        listeners.removeAll()
        if let procID {
            _ = AudioDeviceStop(aggregateID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        Aggregate.destroy(aggregateID)
        aggregateID = .unknown
        if tapID.isValid { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = .unknown
        routes = []
        probe = nil
    }

    private func build(outputs: [OutputDevice], clock: OutputDevice, source: String) throws {
        // 1. Tap what apps play into the AudIO device – only that device, so apps playing
        //    straight to other outputs (a call on headphones) stay untouched. We exclude
        //    ourselves anyway (no feedback), and the sink is silent, so nothing to mute.
        //    A tap is not an audio input, so it doesn't light the microphone indicator.
        let ownProcess = Devices.processObject(for: getpid())
        if !ownProcess.isValid {
            log.warning("Own process object not found; the tap will not exclude AudIO")
        }
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.isValid ? [ownProcess] : [])
        tap.name = "AudIO"
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.deviceUID = source
        tap.stream = 0
        tap.muteBehavior = .unmuted
        try AudioHardwareCreateProcessTap(tap, &tapID).check("Creating the system audio tap")

        // 2. Aggregate of the clock device plus all selected outputs, with the tap as input.
        let subDevices = ([clock] + outputs.filter { $0.uid != clock.uid })
            .map { SubDevice(uid: $0.uid, id: $0.id) }
        aggregateID = try Aggregate.create(
            name: "AudIO", subDevices: subDevices, clockUID: clock.uid, tapUUID: tap.uuid
        )

        // 3. Render graph with one route per selected output.
        let sampleRate = Aggregate.sampleRate(of: aggregateID, fallback: clock.sampleRate)
        let layout = Aggregate.layout(of: aggregateID, subDevices: subDevices)
        // Tap streams follow all sub-device input streams.
        let tapInputIndex = min(layout.inputCount, max(aggregateID.streamCount(kAudioObjectPropertyScopeInput) - 1, 0))
        routes = outputs.compactMap { device in
            layout.outputs[device.uid].map { Route(uid: device.uid, sampleRate: sampleRate, bufferRange: $0) }
        }
        let probe = Probe(sampleRate: sampleRate, routeRanges: routes.map(\.bufferRange))
        self.probe = probe
        let graph = RenderGraph(tapInputIndex: tapInputIndex, routes: routes, probe: probe)
        log.info("Aggregate ready at \(sampleRate) Hz, tap input #\(tapInputIndex), \(self.routes.count) routes")

        // 4. IOProc – called directly on the HAL IO thread (nil queue).
        var proc: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, _, output, outputTime in
            graph.render(input: input, output: output, hostTime: outputTime.pointee.mHostTime)
        }.check("Creating the render callback")
        procID = proc

        listeners = [
            PropertyListener(object: aggregateID, address: .init(kAudioDevicePropertyNominalSampleRate)) {
                [weak self] in self?.onConfigurationLost?()
            },
        ].compactMap { $0 }

        try AudioDeviceStart(aggregateID, proc).check("Starting audio")
    }
}
