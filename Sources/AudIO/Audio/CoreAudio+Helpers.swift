import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        String(localized: "\(operation) failed (\(fourCharCode(UInt32(bitPattern: status))))")
    }
}

/// Renders a Core Audio status or selector as its four-char code when printable, e.g. `'!obj'`.
func fourCharCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
        return String(Int32(bitPattern: value))
    }
    return "'\(String(decoding: bytes, as: UTF8.self))'"
}

extension OSStatus {
    func check(_ operation: @autoclosure () -> String) throws {
        guard self == noErr else { throw CoreAudioError(status: self, operation: operation()) }
    }
}

extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func has(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    func write<T>(_ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        try withUnsafeBytes(of: value) { bytes in
            try AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
                .check(String(localized: "Writing \(fourCharCode(address.mSelector))"))
        }
    }

    func read<T>(_ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        // Explicit byte view avoids the implicit inout-to-raw-pointer conversion warning for generic T.
        try withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        .check(String(localized: "Reading \(fourCharCode(address.mSelector))"))
        return value
    }

    /// Non-throwing read that falls back to `fallback` when the property is missing.
    func value<T>(_ address: AudioObjectPropertyAddress, default fallback: T) -> T {
        (try? read(address, initial: fallback)) ?? fallback
    }

    func readIDs(_ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        try AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
            .check(String(localized: "Sizing \(fourCharCode(address.mSelector))"))
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids)
            .check(String(localized: "Reading \(fourCharCode(address.mSelector))"))
        return ids
    }

    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
            .check(String(localized: "Reading \(fourCharCode(address.mSelector))"))
        return value?.takeRetainedValue() as String? ?? ""
    }

    func streamCount(_ scope: AudioObjectPropertyScope) -> Int {
        ((try? readIDs(.init(kAudioDevicePropertyStreams, scope))) ?? []).count
    }
}

/// Registers a Core Audio property listener for as long as the instance is alive.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var isRegistered = false

    init?(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        isRegistered = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr
        guard isRegistered else { return nil }
    }

    deinit {
        guard isRegistered else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
