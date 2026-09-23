import CoreAudio
import Foundation

struct RouteParameters {
    var delayFrames = 0
    var gain: Float = 1
}

/// One output device inside the aggregate: a stereo delay line plus gain.
///
/// `render` runs on the real-time IO thread: no allocation, no locks. Parameters are
/// written from the main thread into a separately allocated word-aligned block and
/// picked up at the start of the next cycle; gain changes are ramped per buffer.
/// `@unchecked Sendable`: parameters go through a separately allocated block (single word
/// stores), everything else is touched only by the IO thread.
final class Route: @unchecked Sendable {
    let uid: String
    let sampleRate: Double
    /// Indices of this device's streams in the aggregate's output buffer list.
    let bufferRange: Range<Int>
    let maxDelayFrames: Int

    private let parameters: UnsafeMutablePointer<RouteParameters>
    private let ring: UnsafeMutablePointer<Float> // interleaved L/R
    private let mask: Int
    private var writeIndex = 0
    private var currentGain: Float = 0

    init(uid: String, sampleRate: Double, bufferRange: Range<Int>, maxDelaySeconds: Double = 1) {
        self.uid = uid
        self.sampleRate = sampleRate
        self.bufferRange = bufferRange
        maxDelayFrames = Int(sampleRate * maxDelaySeconds)

        // Power-of-two capacity with headroom for the largest IO buffer.
        let minimumCapacity = maxDelayFrames + 16_384
        let capacity = sequence(first: 1) { $0 << 1 }.first { $0 >= minimumCapacity } ?? 1 << 17
        mask = capacity - 1
        ring = .allocate(capacity: capacity * 2)
        ring.initialize(repeating: 0, count: capacity * 2)
        parameters = .allocate(capacity: 1)
        parameters.initialize(to: RouteParameters())
    }

    deinit {
        ring.deallocate()
        parameters.deallocate()
    }

    func set(delayMs: Double, gain: Float) {
        let frames = Int((delayMs * sampleRate / 1000).rounded())
        parameters.pointee = RouteParameters(
            delayFrames: min(max(frames, 0), maxDelayFrames),
            gain: max(gain, 0)
        )
    }

    func render(
        source: UnsafePointer<Float>?,
        sourceChannels: Int,
        frames: Int,
        output: UnsafeMutableAudioBufferListPointer
    ) {
        // Map the first two channels across this device's streams to L/R, silence the rest.
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var leftStride = 0
        var rightStride = 0
        var frameCount = frames
        var channel = 0

        for index in bufferRange where index < output.count {
            let buffer = output[index]
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue } // zeroed by the graph
            let channels = Int(buffer.mNumberChannels)
            frameCount = min(frameCount, Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))
            let samples = data.assumingMemoryBound(to: Float.self)
            for offset in 0..<channels {
                if channel == 0 {
                    left = samples + offset
                    leftStride = channels
                } else if channel == 1 {
                    right = samples + offset
                    rightStride = channels
                }
                channel += 1
            }
        }

        let target = parameters.pointee
        let delay = target.delayFrames
        let isMono = right == nil
        let step = (target.gain - currentGain) / Float(max(frameCount, 1))
        var gain = currentGain
        var write = writeIndex

        for frame in 0..<max(frameCount, 0) {
            var l: Float = 0
            var r: Float = 0
            if let source {
                l = source[frame * sourceChannels]
                r = sourceChannels > 1 ? source[frame * sourceChannels + 1] : l
            }
            ring[write << 1] = l
            ring[(write << 1) + 1] = r

            let read = (write - delay) & mask
            let dl = ring[read << 1]
            let dr = ring[(read << 1) + 1]
            gain += step

            left?[frame * leftStride] = (isMono ? (dl + dr) * 0.5 : dl) * gain
            right?[frame * rightStride] = dr * gain
            write = (write + 1) & mask
        }

        writeIndex = write
        currentGain = target.gain
    }
}

/// Immutable per-aggregate render setup; rebuilt whenever the device group changes.
final class RenderGraph {
    let tapInputIndex: Int
    let routes: [Route]
    let probe: Probe?

    init(tapInputIndex: Int, routes: [Route], probe: Probe?) {
        self.tapInputIndex = tapInputIndex
        self.routes = routes
        self.probe = probe
    }

    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        hostTime: UInt64
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        var source: UnsafePointer<Float>?
        var channels = 2
        var frames = 0

        if tapInputIndex < inputs.count {
            let buffer = inputs[tapInputIndex]
            channels = max(Int(buffer.mNumberChannels), 1)
            frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            source = buffer.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
        }
        if source == nil, let first = outputs.first, first.mNumberChannels > 0 {
            // No tap data this cycle: keep the delay lines moving with silence.
            frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        }

        // Unrouted sub-devices (e.g. an unselected clock device) must stay silent.
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        for route in routes {
            route.render(source: source, sourceChannels: channels, frames: frames, output: outputs)
        }
        // While measuring, the probe replaces the program audio with test tones.
        probe?.render(outputs: outputs, frames: frames, hostTime: hostTime)
    }
}
