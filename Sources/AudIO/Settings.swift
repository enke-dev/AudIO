import Foundation

struct RouteSettings: Codable, Equatable {
    var isSelected = false
    var delayMs: Double = 0
    /// The output's own level (0…1), before the master. Devices with hardware volume get
    /// level × master on the device itself, the others in software.
    var level: Double = 1

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isSelected, delayMs, level
        case softwareVolume // before 0.4: the level of devices without hardware volume
    }

    // Tolerant decoding so older or partial stored settings don't reset everything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        delayMs = try container.decodeIfPresent(Double.self, forKey: .delayMs) ?? 0
        level = try container.decodeIfPresent(Double.self, forKey: .level)
            ?? container.decodeIfPresent(Double.self, forKey: .softwareVolume) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isSelected, forKey: .isSelected)
        try container.encode(delayMs, forKey: .delayMs)
        try container.encode(level, forKey: .level)
    }
}

/// UserDefaults-backed persistence; route settings are keyed by device UID so a
/// reconnecting Bluetooth device gets its calibration back.
struct SettingsStore {
    private enum Key {
        static let routes = "routes"
        static let previousOutput = "previousOutputUID"
        static let resumeDriver = "resumeDriver"
    }

    private let defaults = UserDefaults.standard

    /// Output device to return to when AudIO (the driver device) is switched off.
    var previousOutputUID: String? {
        get { defaults.string(forKey: Key.previousOutput) }
        nonmutating set { defaults.set(newValue, forKey: Key.previousOutput) }
    }

    /// AudIO was the system output when the app quit – select it again on launch.
    var resumeDriver: Bool {
        get { defaults.bool(forKey: Key.resumeDriver) }
        nonmutating set { defaults.set(newValue, forKey: Key.resumeDriver) }
    }

    var routes: [String: RouteSettings] {
        get {
            defaults.data(forKey: Key.routes)
                .flatMap { try? JSONDecoder().decode([String: RouteSettings].self, from: $0) } ?? [:]
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.routes) }
    }
}
