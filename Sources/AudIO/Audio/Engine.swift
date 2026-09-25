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
    /// How long the capture takes (see `captureLatency(of:)`), in seconds.
    private(set) var captureLatency: Double = 0

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
        captureLatency = 0
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
        // The device initializer: a global tap with `deviceUID` set afterwards still captures
        // every device – system sounds played straight to an output came out twice.
        let tap = CATapDescription(
            excludingProcesses: ownProcess.isValid ? [ownProcess] : [], deviceUID: source, stream: 0
        )
        tap.name = "AudIO"
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try AudioHardwareCreateProcessTap(tap, &tapID).check(String(localized: "Creating the system audio tap"))

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
        captureLatency = Self.captureLatency(of: aggregateID, sampleRate: sampleRate)
        try AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, _, output, outputTime in
            graph.render(input: input, output: output, hostTime: outputTime.pointee.mHostTime)
        }.check(String(localized: "Creating the render callback"))
        procID = proc

        listeners = [
            PropertyListener(object: aggregateID, address: .init(kAudioDevicePropertyNominalSampleRate)) {
                [weak self] in self?.onConfigurationLost?()
            },
        ].compactMap { $0 }

        try AudioDeviceStart(aggregateID, proc).check(String(localized: "Starting audio"))
    }

    /// How long the capture takes – from a sample handed to the AudIO device until it
    /// leaves the render graph. Core Audio doesn't report it as a latency, but it follows
    /// from the aggregate: its output minus input time stamp is two IO buffers plus both
    /// safety offsets (into which it folds the sub-devices' latencies), then the tapped
    /// input's latency. Checked against clicks timed through the tap: 106 / 26 / 188 ms
    /// (Creative, built-in, both), within 1 ms.
    private static func captureLatency(of aggregate: AudioObjectID, sampleRate: Double) -> Double {
        let input = kAudioObjectPropertyScopeInput
        let output = kAudioObjectPropertyScopeOutput
        let frames = [
            (kAudioDevicePropertyBufferFrameSize, output), (kAudioDevicePropertyBufferFrameSize, output),
            (kAudioDevicePropertySafetyOffset, input), (kAudioDevicePropertySafetyOffset, output),
            (kAudioDevicePropertyLatency, input),
        ].map { aggregate.value(.init($0.0, $0.1), default: UInt32(0)) }.reduce(0, +)
        return Double(frames) / sampleRate
    }
}
