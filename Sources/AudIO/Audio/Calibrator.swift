import Accelerate
import CoreAudio
import Foundation

/// Measures each output's real latency acoustically, inside the running routing session.
///
/// The engine's `Probe` plays a short log sweep through one output at a time while the
/// default input records with its own IOProc. Both sides report host times, so each
/// sweep's emission time maps onto the recording; cross-correlation finds its arrival.
/// Constant offsets (mic latency, IO buffering) are equal for all outputs and cancel out –
/// only relative latencies are used.
enum Calibrator {
    enum Failure: LocalizedError {
        case notRouting
        case noMicrophone
        case noSignal([String])

        var errorDescription: String? {
            switch self {
            case .notRouting: String(localized: "Select AudIO as sound output and tick at least two outputs first")
            case .noMicrophone: String(localized: "No microphone found – select an input device in the Sound settings")
            case .noSignal(let names):
                String(localized: "No test tone detected from \(names.formatted(.list(type: .and))) – turn it up and keep the room quiet")
            }
        }
    }

    private static let runs = 3
    private static let leadIn = Duration.milliseconds(300)
    private static let warmUp = Duration.milliseconds(1200)
    private static let slot = Duration.seconds(1)

    /// Expected duration in seconds, for the UI.
    static func duration(deviceCount: Int) -> Double {
        0.3 + 1.2 + Double(deviceCount * runs) * 1.0
    }

    /// Returns each routed output's latency in ms (relative to a common offset), by UID.
    @MainActor
    static func measure(probe: Probe, routes: [Route], devices: [OutputDevice]) async throws -> [String: Double] {
        guard routes.count >= 2 else { throw Failure.notRouting }
        let uids = routes.map(\.uid)

        let micID = AudioObjectID.system.value(.init(kAudioHardwarePropertyDefaultInputDevice), default: AudioDeviceID.unknown)
        guard micID.isValid else { throw Failure.noMicrophone }
        let mic = MicRecorder(deviceID: micID, seconds: duration(deviceCount: uids.count) + 2)
        try mic.start()
        probe.setMeasuring(true)
        defer {
            probe.setMeasuring(false)
            mic.stop()
        }

        // Warm-up on all outputs wakes Bluetooth speakers and lets their level settle.
        try await Task.sleep(for: leadIn)
        _ = probe.fire(route: nil)
        try await Task.sleep(for: warmUp)

        var shots: [(device: Int, sequence: Int)] = []
        for _ in 0..<runs {
            for device in uids.indices {
                shots.append((device, probe.fire(route: device)))
                try await Task.sleep(for: slot)
            }
        }
        probe.setMeasuring(false)
        mic.stop()

        let names = uids.map { uid in devices.first { $0.uid == uid }?.name ?? uid }
        guard mic.firstHostTime != 0 else { throw Failure.noSignal(names) }

        let recording = mic.recording
        let sampleRate = mic.sampleRate
        let startNanos = Double(AudioConvertHostTimeToNanos(mic.firstHostTime))
        let emissions = shots.compactMap { shot in
            probe.emitHostTime(of: shot.sequence).map {
                Emission(device: shot.device, nanos: Double(AudioConvertHostTimeToNanos($0)))
            }
        }

        let latencies = await Task.detached(priority: .userInitiated) {
            analyze(recording: recording, sampleRate: sampleRate, startNanos: startNanos, emissions: emissions)
        }.value

        let missing = uids.indices.filter { latencies[$0] == nil }.map { names[$0] }
        guard missing.isEmpty else { throw Failure.noSignal(missing) }
        return uids.indices.reduce(into: [:]) { $0[uids[$1]] = latencies[$1] }
    }

    private struct Emission {
        let device: Int
        let nanos: Double
    }

    /// Cross-correlates the recording around every emission with the sweep; returns the
    /// median latency (ms) per device index, for devices with at least two clear detections.
    private static func analyze(
        recording: [Float],
        sampleRate: Double,
        startNanos: Double,
        emissions: [Emission]
    ) -> [Int: Double] {
        let sweep = Sweep.samples(sampleRate: sampleRate)
        let lead = Int(0.1 * sampleRate)     // tolerance before the expected position
        let search = Int(0.8 * sampleRate)   // covers Bluetooth latency + IO offsets
        var correlation = [Float](repeating: 0, count: search)

        let latencies = emissions.reduce(into: [Int: [Double]]()) { result, emission in
            let expected = (emission.nanos - startNanos) / 1e9 * sampleRate
            let windowStart = Int(expected) - lead
            guard windowStart >= 0, windowStart + search + sweep.count <= recording.count else { return }

            recording.withUnsafeBufferPointer { signal in
                vDSP_conv(
                    signal.baseAddress! + windowStart, 1,
                    sweep, 1,
                    &correlation, 1,
                    vDSP_Length(search), vDSP_Length(sweep.count)
                )
            }
            var peak: Float = 0
            var index: vDSP_Length = 0
            var rms: Float = 0
            vDSP_maxmgvi(correlation, 1, &peak, &index, vDSP_Length(search))
            vDSP_rmsqv(correlation, 1, &rms, vDSP_Length(search))

            // A clear sweep gives a sharp peak far above the correlation floor.
            guard rms > 0, peak / rms > 8 else { return }
            let arrival = Double(windowStart) + Double(index)
            result[emission.device, default: []].append((arrival - expected) / sampleRate * 1000)
        }

        return latencies.reduce(into: [:]) { result, entry in
            let sorted = entry.value.sorted()
            guard sorted.count >= 2 else { return }
            result[entry.key] = sorted[sorted.count / 2]
        }
    }
}
