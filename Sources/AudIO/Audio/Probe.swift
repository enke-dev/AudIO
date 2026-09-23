import CoreAudio
import Foundation

/// Exponential sine sweep with raised-cosine fades – the calibration test tone.
enum Sweep {
    static let duration = 0.25

    static func samples(sampleRate: Double, from f0: Double = 300, to f1: Double = 10_000) -> [Float] {
        let count = Int(duration * sampleRate)
        let ratio = log(f1 / f0)
        let fade = Int(0.01 * sampleRate)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            let phase = 2 * Double.pi * f0 * duration / ratio * (exp(t / duration * ratio) - 1)
            let edge = min(index, count - 1 - index)
            let window = edge < fade ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade)) : 1
            return Float(sin(phase) * window)
        }
    }
}

/// Test-tone injector inside the running render graph, so a measurement hits exactly the
/// stream that is playing – no aggregate rebuild, no Bluetooth stream restart.
///
/// While measuring, program audio is silenced and each `fire` plays one sweep on one
/// route (or all). The IO thread stamps the host time of the cycle the sweep starts in.
/// `@unchecked Sendable`: shared state lives in word-sized slots (see below); the rest is
/// confined to either the main thread or the IO thread.
final class Probe: @unchecked Sendable {
    private static let capacity = 64

    let sampleRate: Double
    private let sweep: [Float]
    private let routeRanges: [Range<Int>]

    // Shared words (single aligned stores): [0] measuring flag, [1] request = seq << 8 | route + 1.
    private let shared: UnsafeMutablePointer<Int>
    private let emitTimes: UnsafeMutablePointer<UInt64>

    // Main thread only.
    private var sequence = 0

    // IO thread only.
    private var handled = 0
    private var isPlaying = false
    private var playRoute = -1
    private var playGain: Float = 0
    private var playOffset = 0

    init(sampleRate: Double, routeRanges: [Range<Int>]) {
        self.sampleRate = sampleRate
        self.routeRanges = routeRanges
        sweep = Sweep.samples(sampleRate: sampleRate)
        shared = .allocate(capacity: 2)
        shared.initialize(repeating: 0, count: 2)
        emitTimes = .allocate(capacity: Self.capacity)
        emitTimes.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        shared.deallocate()
        emitTimes.deallocate()
    }

    // MARK: Main thread

    func setMeasuring(_ measuring: Bool) {
        shared[0] = measuring ? 1 : 0
    }

    /// Plays the sweep once on route `index` (nil = all routes). Returns its sequence number.
    func fire(route index: Int?) -> Int {
        sequence += 1
        emitTimes[sequence % Self.capacity] = 0
        shared[1] = sequence << 8 | ((index ?? -1) + 1)
        return sequence
    }

    /// Host time of the output cycle the sweep started in, once it was played.
    func emitHostTime(of sequence: Int) -> UInt64? {
        let time = emitTimes[sequence % Self.capacity]
        return time == 0 ? nil : time
    }

    // MARK: IO thread

    func render(outputs: UnsafeMutableAudioBufferListPointer, frames: Int, hostTime: UInt64) {
        guard shared[0] != 0 else {
            isPlaying = false
            return
        }
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let request = shared[1]
        let requested = request >> 8
        if requested != handled {
            handled = requested
            playRoute = (request & 0xFF) - 1
            playGain = playRoute < 0 ? 0.25 : 0.5
            playOffset = 0
            isPlaying = true
            emitTimes[requested % Self.capacity] = hostTime
        }
        guard isPlaying else { return }

        let count = min(frames, sweep.count - playOffset)
        for (index, range) in routeRanges.enumerated() where playRoute < 0 || playRoute == index {
            for bufferIndex in range where bufferIndex < outputs.count {
                let buffer = outputs[bufferIndex]
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let channels = Int(buffer.mNumberChannels)
                let capacity = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<min(count, capacity) {
                    let value = sweep[playOffset + frame] * playGain
                    for channel in 0..<channels { samples[frame * channels + channel] = value }
                }
            }
        }
        playOffset += max(count, 0)
        if playOffset >= sweep.count { isPlaying = false }
    }
}

/// Records the first channel of an input device with its own IOProc, stamped with the
/// host time of the first captured frame.
final class MicRecorder {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    // [0] frames written, [1] host time of frame 0.
    private let state: UnsafeMutablePointer<UInt64>
    private var procID: AudioDeviceIOProcID?

    init(deviceID: AudioDeviceID, seconds: Double) {
        self.deviceID = deviceID
        let actual = deviceID.value(.init(kAudioDevicePropertyActualSampleRate), default: Float64(0))
        let nominal = deviceID.value(.init(kAudioDevicePropertyNominalSampleRate), default: Float64(48_000))
        sampleRate = actual > 0 ? actual : nominal
        capacity = Int(seconds * sampleRate)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        state = .allocate(capacity: 2)
        state.initialize(repeating: 0, count: 2)
    }

    deinit {
        stop()
        buffer.deallocate()
        state.deallocate()
    }

    var firstHostTime: UInt64 { state[1] }

    var recording: [Float] {
        Array(UnsafeBufferPointer(start: buffer, count: Int(state[0])))
    }

    func start() throws {
        var proc: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) { [unowned self] _, input, inputTime, _, _ in
            self.capture(input, hostTime: inputTime.pointee.mHostTime)
        }.check("Opening the microphone")
        procID = proc
        try AudioDeviceStart(deviceID, proc).check("Starting the microphone")
    }

    func stop() {
        guard let procID else { return }
        _ = AudioDeviceStop(deviceID, procID)
        _ = AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }

    private func capture(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = inputs.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        let written = Int(state[0])
        if written == 0 { state[1] = hostTime }

        let count = min(frames, capacity - written)
        guard count > 0 else { return }
        let source = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<count { buffer[written + frame] = source[frame * channels] }
        state[0] = UInt64(written + count)
    }
}
