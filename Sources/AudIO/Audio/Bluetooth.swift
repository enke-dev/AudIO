import AppKit
import IOBluetooth

/// A paired Bluetooth audio device – listed while it has no sound output, so it can be
/// connected from the panel like in the Sound menu.
struct BluetoothDevice: Identifiable, Hashable {
    /// Upper-case, dash-separated – the form Core Audio's device UIDs start with
    /// ("F8-D3-F0-BF-61-55:output").
    let address: String
    let name: String
    let symbolName: String

    var id: String { address }
}

enum Bluetooth {
    /// Paired audio devices – the caller leaves out those with a sound output. Connected
    /// ones count too: AirPods taken out of the ears stay connected, without an output.
    /// Asks for Bluetooth access the first time.
    static func audioDevices() -> [BluetoothDevice] {
        pairedAudioDevices()
            .compactMap { device in
                guard let address = device.addressString else { return nil }
                return BluetoothDevice(
                    address: normalized(address),
                    name: device.name ?? address,
                    symbolName: symbolName(minorClass: device.deviceClassMinor)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Connects a paired device – blocks for up to several seconds, so off the main thread.
    /// One still connected without a sound output (AirPods out of the ears) is reconnected:
    /// connecting again would do nothing.
    static func connect(address: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { connectBlocking(address: address) }.value
    }

    private static func connectBlocking(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        if device.isConnected() {
            _ = device.closeConnection()
            // Disconnecting completes asynchronously; opening meanwhile fails.
            for _ in 0..<30 where device.isConnected() { Thread.sleep(forTimeInterval: 0.1) }
        }
        return device.openConnection() == kIOReturnSuccess
    }

    /// The Bluetooth address of an output, if it is one ("F8-D3-F0-BF-61-55:output").
    static func address(of output: OutputDevice) -> String? {
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].map { UInt32($0) }
        guard bluetooth.contains(output.transportType), let colon = output.uid.firstIndex(of: ":") else { return nil }
        return String(output.uid[..<colon]).uppercased()
    }

    /// Whether a Core Audio device UID belongs to the Bluetooth device.
    static func matches(uid: String, address: String) -> Bool {
        uid.uppercased().hasPrefix(address + ":")
    }

    /// Symbol for a connected Bluetooth output: the exact model for Apple's (AirPods,
    /// Beats), else by device class, like the Sound menu.
    static func symbolName(uid: String, modelUID: String?) -> String {
        if let symbol = modelUID.flatMap(appleSymbol(modelUID:)) { return symbol }
        let address = String(uid.prefix { $0 != ":" })
        let minor = pairedAudioDevices()
            .first { $0.addressString.map(normalized) == address }?
            .deviceClassMinor
        return symbolName(minorClass: minor ?? 0)
    }

    private static func pairedAudioDevices() -> [IOBluetoothDevice] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) }
    }

    private static func normalized(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: ":", with: "-")
    }

    private static func symbolName(minorClass: BluetoothDeviceClassMinor) -> String {
        switch Int(minorClass) {
        case kBluetoothDeviceClassMinorAudioHeadphones: "headphones"
        case kBluetoothDeviceClassMinorAudioHeadset, kBluetoothDeviceClassMinorAudioHandsFree: "headset"
        case kBluetoothDeviceClassMinorAudioCar: "car.fill"
        case kBluetoothDeviceClassMinorAudioLoudspeaker, kBluetoothDeviceClassMinorAudioHiFi,
             kBluetoothDeviceClassMinorAudioPortable: "hifispeaker.fill"
        default: "speaker.wave.2.fill"
        }
    }

    /// Apple's model UIDs are "<product id> <vendor id>" in hex, vendor 4c.
    private static func appleSymbol(modelUID: String) -> String? {
        let parts = modelUID.lowercased().split(separator: " ")
        guard parts.count == 2, parts[1] == "4c", let product = Int(parts[0], radix: 16),
              let symbol = appleProducts[product]
        else { return nil }
        // Newer symbols (e.g. airpods.gen4) don't exist on older macOS.
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "headphones"
    }

    private static let appleProducts: [Int: String] = [
        0x2002: "airpods", 0x200F: "airpods", 0x2013: "airpods.gen3",
        0x2019: "airpods.gen4", 0x201B: "airpods.gen4",
        0x200E: "airpodspro", 0x2014: "airpodspro", 0x2024: "airpodspro", 0x2027: "airpodspro",
        0x200A: "airpodsmax", 0x201F: "airpodsmax",
        0x2003: "beats.powerbeats3", 0x200B: "beats.powerbeatspro", 0x200D: "beats.powerbeats",
        0x2005: "beats.earphones", 0x2006: "beats.headphones", 0x2009: "beats.headphones",
        0x200C: "beats.headphones", 0x2017: "beats.headphones",
        0x2011: "beats.studiobuds", 0x2016: "beats.studiobudsplus", 0x2012: "beats.fitpro",
    ]
}
