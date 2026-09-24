// Measures the lip-sync error of the current sound output: plays clicks at known times and
// compares when the microphone hears them with when the output says they'll be heard
// (its presentation latency – what video players delay the picture by).
//
//   swift scripts/lipsync.swift        (Terminal needs microphone access)
//
// Run it once with the AirPods (or a speaker) selected directly and once with AudIO
// routing to the same output. Result ≈ 0 ms: in sync. Positive: sound late (picture
// ahead). Use a speaker the Mac's microphone can hear – AirPods in your ears won't do.
import AVFoundation
import CoreAudio

func seconds(_ ticks: UInt64) -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func defaultOutputName() -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    address.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
    return name?.takeRetainedValue() as String? ?? "?"
}

let clicks = 6
let spacing = 1.0

// Output: a player node scheduling short clicks at exact host times.
let output = AVAudioEngine()
let player = AVAudioPlayerNode()
output.attach(player)
let format = output.outputNode.outputFormat(forBus: 0)
let playFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
output.connect(player, to: output.mainMixerNode, format: playFormat)
// A 10 ms 2 kHz burst – short enough to time, loud enough for any microphone.
let clickFrames = AVAudioFrameCount(playFormat.sampleRate * 0.01)
let click = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: clickFrames)!
click.frameLength = clickFrames
for channel in 0..<2 {
    for i in 0..<Int(clickFrames) {
        click.floatChannelData![channel][i] = 0.9 * sin(2 * .pi * 2000 * Float(i) / Float(playFormat.sampleRate))
    }
}

// Input: the whole microphone signal, with the host time of every buffer.
let input = AVAudioEngine()
let inputFormat = input.inputNode.outputFormat(forBus: 0)
var recording: [(start: Double, samples: [Float])] = []
let lock = NSLock()
input.inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, when in
    guard when.isHostTimeValid, let data = buffer.floatChannelData?[0] else { return }
    let chunk = (seconds(when.hostTime), Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
    lock.lock(); recording.append(chunk); lock.unlock()
}

do {
    try input.start()
    try output.start()
} catch {
    print("Couldn't start audio: \(error)")
    exit(1)
}
player.play()
Thread.sleep(forTimeInterval: 1.0) // let the noise floor settle

let outputLatency = output.outputNode.presentationLatency
let inputLatency = input.inputNode.presentationLatency
let now = mach_absolute_time()
var expected: [Double] = []
for n in 0..<clicks {
    let at = now + UInt64((1.0 + Double(n) * spacing) / seconds(1))
    player.scheduleBuffer(click, at: AVAudioTime(hostTime: at))
    expected.append(seconds(at) + outputLatency)
}
Thread.sleep(forTimeInterval: 1.5 + Double(clicks) * spacing + 1.0)
output.stop()
input.stop()

lock.lock()
let chunks = recording
lock.unlock()
let rate = inputFormat.sampleRate
let peak = chunks.flatMap(\.samples).map(abs).max() ?? 0
// Per click: the first sample above 30 % of the loudest one within ±0.5 s of the expectation.
let errors = expected.compactMap { expect -> Double? in
    let window = chunks.flatMap { chunk in
        chunk.samples.enumerated().map { (time: chunk.start + Double($0.offset) / rate - inputLatency, level: abs($0.element)) }
    }.filter { abs($0.time - expect) < spacing / 2 }
    guard let loudest = window.map(\.level).max(), loudest > 0.01 else { return nil }
    return window.first { $0.level > loudest * 0.3 }.map { $0.time - expect }
}
print("Output: \(defaultOutputName())")
print(String(format: "Reported presentation latency: %.0f ms", outputLatency * 1000))
guard !errors.isEmpty else {
    print(String(format: "No clicks detected (microphone peak %.3f) – %@", peak,
                 peak == 0 ? "no microphone signal: allow Terminal in Privacy & Security › Microphone"
                           : "turn the volume up, use a speaker the microphone can hear"))
    exit(1)
}
let sorted = errors.sorted()
let median = sorted[sorted.count / 2]
print(String(format: "Lip-sync error: %+.0f ms (median of %d clicks, spread %.0f…%+.0f ms)",
             median * 1000, errors.count, sorted.first! * 1000, sorted.last! * 1000))
