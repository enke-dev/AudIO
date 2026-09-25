import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import OSLog
import SwiftUI

private let latencyLog = Logger(subsystem: "dev.enke.AudIO", category: "latency")

/// Main-thread state: device list, user settings, and reconciling both with the engine.
@MainActor
final class Router: ObservableObject {
    enum Status: Equatable {
        case disabled
        /// Engine is being (re)built – can wait on the system audio recording permission.
        case starting
        /// Routing what apps play into AudIO; `count` outputs play it, 0 means silence.
        case routing(count: Int)
        case failed(String)
    }

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var status: Status = .disabled
    /// The AudIO driver device, when installed. AudIO routes exactly while it is the
    /// system output; its volume is the master (published by the driver, applied here).
    @Published private(set) var driver: SubDevice?
    @Published private var defaultOutputID = AudioDeviceID.unknown
    /// Volume and mute of the AudIO device – the master, applied after the delay lines.
    @Published private(set) var driverVolume: Double = 1
    @Published private(set) var isDriverMuted = false
    @Published private(set) var driverState = DriverInstaller.state
    @Published private(set) var isInstallingDriver = false
    @Published private(set) var driverError: String?

    @Published var routes: [String: RouteSettings] {
        didSet {
            store.routes = routes
            // A changed selection is worth another try after a failed start.
            let selected = { (routes: [String: RouteSettings]) in Set(routes.filter { $0.value.isSelected }.keys) }
            if selected(routes) != selected(oldValue) { failedKey = nil }
            reconcile()
        }
    }

    enum Calibration: Equatable {
        case measuring(String)
        case failed(String)
    }

    @Published private(set) var calibration: Calibration?

    private var isCalibrating: Bool {
        if case .measuring = calibration { true } else { false }
    }

    /// AudIO is the system output – routing runs and the controls are live.
    var isDriverActive: Bool {
        driver.map { $0.id == defaultOutputID } ?? false
    }

    /// A line under the title – only for what needs attention: errors, a running measurement.
    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    var notice: Notice? {
        if let driverError { return Notice(text: driverError, isError: true) }
        return switch (calibration, status) {
        case (.measuring(let text), _): Notice(text: text, isError: false)
        case (.failed(let text), _): Notice(text: text, isError: true)
        case (_, .failed(let text)): Notice(text: text, isError: true)
        case (_, .starting) where isSlowStart:
            Notice(text: String(localized: "Starting… if macOS asks, allow system audio recording"), isError: false)
        default: nil
        }
    }

    /// Controls are live: driver installed, AudIO is the sound output, no install running.
    var isReady: Bool {
        driver != nil && isDriverActive && !isInstallingDriver
    }

    /// Selects AudIO as system output (the header button when it isn't).
    func activate() {
        failedKey = nil // a manual activation deserves a fresh start attempt
        selectAudIO(true)
    }

    private let store: SettingsStore
    private let engine = Engine()
    private var runningKey: [String]?
    /// Engine start/stop runs on its own serial queue: starting the tap can block until the
    /// user answers the system audio recording prompt, which must never freeze the UI.
    private let engineQueue = DispatchQueue(label: "dev.enke.AudIO.engine", qos: .userInitiated)
    private var pendingKey: [String]?
    /// Configuration whose start failed. Not retried automatically: building/tearing down the
    /// aggregate itself fires "devices changed", which would otherwise loop forever.
    private var failedKey: [String]?
    private var generation = 0
    /// A start that takes a while (usually waiting for the recording permission) – only
    /// then the "Starting…" notice appears; quick restarts would just make the menu jump.
    @Published private var isSlowStart = false
    private var slowStartTask: Task<Void, Never>?
    /// Routes and probe of the running engine, handed over from the engine queue – the
    /// engine itself is only touched on that queue.
    private var activeRoutes: [Route] = []
    private var activeProbe: Probe?
    private var captureLatency: Double?
    private var isEngineRunning = false
    private var systemListeners: [PropertyListener] = []
    private var volumeListeners: [PropertyListener] = []
    private var refreshTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        let store = SettingsStore()
        self.store = store
        _routes = Published(initialValue: store.routes)

        engine.onConfigurationLost = { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        systemListeners = makeSystemListeners()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        refresh()
        if store.resumeDriver, driver != nil, !isDriverActive { selectAudIO(true) }
    }

    private func makeSystemListeners() -> [PropertyListener] {
        // Device lists change in bursts (debounced); a switched system output is acted on at
        // once – every millisecond there is a gap in the sound.
        [
            PropertyListener(object: .system, address: .init(kAudioHardwarePropertyDevices)) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            },
            PropertyListener(object: .system, address: .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isInstallingDriver else { return }
                    self.refreshTask?.cancel()
                    self.refresh()
                }
            },
        ].compactMap { $0 }
    }

    /// Installs (or updates) the driver bundled with the app, then selects AudIO.
    func installDriver() {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        driverError = nil

        // Core Audio restarts during the install: every device/tap object we hold dies, and
        // any HAL call on the main thread would block until it's back (= frozen UI). So stop
        // routing and drop all listeners now, and only wait for the device off the main thread.
        halt(status)
        refreshTask?.cancel()
        systemListeners = []
        volumeListeners = []

        Task {
            do {
                try await DriverInstaller.install()
                await DriverInstaller.waitForDevice()
                isInstallingDriver = false
                reconnect()
                selectAudIO(true)
            } catch {
                isInstallingDriver = false
                if !(error is CancellationError) {
                    driverError = String(localized: "Installing the audio device failed: \(error.localizedDescription)")
                }
                reconnect()
            }
        }
    }

    /// After a Core Audio restart: re-register listeners and rebuild everything.
    private func reconnect() {
        systemListeners = makeSystemListeners()
        runningKey = nil
        failedKey = nil
        refresh()
    }

    /// Don't leave the system output on AudIO without the app routing it (= silence).
    private func shutdown() {
        store.resumeDriver = isDriverActive
        // Synchronous on purpose: the app is about to exit.
        if isDriverActive, let target = outputTarget(audIO: false) { Devices.setDefaultOutput(target) }
        // Private tap and aggregate die with the process anyway.
        engineQueue.async { [engine] in engine.stop() }
    }

    /// Switching the system output can take a moment while Core Audio (re)starts devices –
    /// done off the main thread so the panel stays responsive. The listener reports back.
    private func selectAudIO(_ on: Bool) {
        guard on != isDriverActive, let target = outputTarget(audIO: on) else { return }
        if on { store.previousOutputUID = defaultOutputUID }
        Task.detached(priority: .userInitiated) { Devices.setDefaultOutput(target) }
    }

    private func outputTarget(audIO on: Bool) -> AudioDeviceID? {
        if on { return driver?.id }
        let builtIn = UInt32(kAudioDeviceTransportTypeBuiltIn)
        return (devices.first { $0.uid == store.previousOutputUID }
            ?? devices.first { $0.transportType == builtIn }
            ?? devices.first)?.id
    }

    // MARK: - UI API

    func binding(for uid: String) -> Binding<RouteSettings> {
        Binding(
            get: { [weak self] in
                MainActor.assumeIsolated { self?.routes[uid] ?? RouteSettings() }
            },
            set: { [weak self] value in
                MainActor.assumeIsolated { self?.routes[uid] = value }
            }
        )
    }

    func volumeBinding(for uid: String) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                MainActor.assumeIsolated { self?.routes[uid]?.level ?? 1 }
            },
            set: { [weak self] value in
                MainActor.assumeIsolated { self?.setVolume(value, for: uid) }
            }
        )
    }

    func driverVolumeBinding() -> Binding<Double> {
        Binding(
            get: { [weak self] in
                MainActor.assumeIsolated { self?.driverVolume ?? 1 }
            },
            set: { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, let driver = self.driver else { return }
                    self.driverVolume = value.clamped01
                    self.applyParameters() // don't wait for the listener round trip
                    self.pushHardwareVolumes()
                    Volume.write(value, to: driver.id)
                }
            }
        )
    }

    func setVolume(_ value: Double, for uid: String) {
        routes[uid, default: RouteSettings()].level = value.clamped01 // → reconcile → hardware
    }

    var canMeasure: Bool { selectedDevices.count >= 2 && isEngineRunning && !isCalibrating }

    /// Measures every selected output acoustically, inside the running stream, and sets the
    /// delays so all line up with the slowest one. Program audio pauses for a few seconds.
    func measureDelays() {
        guard canMeasure else { return }
        let devices = selectedDevices

        calibration = .measuring(String(localized: "Waiting for microphone access…"))
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                calibration = .failed(String(localized: "Microphone access denied – allow AudIO in Privacy & Security › Microphone"))
                return
            }
            let seconds = Int(Calibrator.duration(deviceCount: devices.count).rounded(.up))
            calibration = .measuring(String(localized: "Measuring for about \(seconds) s – keep the room quiet"))

            do {
                guard let probe = activeProbe else { throw Calibrator.Failure.notRouting }
                let latencies = try await Calibrator.measure(probe: probe, routes: activeRoutes, devices: devices)
                let slowest = latencies.values.max() ?? 0
                calibration = nil
                // Same device set → reconcile only updates parameters, the stream keeps running.
                routes = latencies.reduce(into: routes) { result, entry in
                    result[entry.key, default: RouteSettings()].delayMs = (slowest - entry.value).rounded()
                }
            } catch {
                calibration = .failed(error.localizedDescription)
                reconcile()
            }
        }
    }

    // MARK: - Reconciliation

    private var selectedDevices: [OutputDevice] {
        devices.filter { routes[$0.uid]?.isSelected == true }
    }

    private func scheduleRefresh() {
        // Device changes arrive in bursts (Bluetooth connect, our own aggregate) – debounce.
        guard !isInstallingDriver else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        devices = Devices.outputs()
        driver = Devices.virtualDevice()
        driverState = DriverInstaller.state
        defaultOutputID = Devices.defaultOutput()
        defaultOutputUID = devices.first { $0.id == defaultOutputID }?.uid
        syncDriverVolume()
        observeVolumes()
        reconcile()
    }

    private func restart() {
        runningKey = nil
        failedKey = nil
        reconcile()
    }

    private func reconcile() {
        guard !isCalibrating else { return } // the calibrator owns the devices meanwhile
        updatePremix()
        let selected = selectedDevices

        // Requires the driver: on while AudIO (a silent sink) is the system output; the tap
        // captures what apps play into it. With nothing selected it's simply silent.
        // A real device (built-in preferred) clocks the group.
        guard let driver, isDriverActive else { return halt(.disabled) }
        let builtIn = UInt32(kAudioDeviceTransportTypeBuiltIn)
        guard let clock = selected.first(where: { $0.transportType == builtIn }) ?? selected.first else {
            return halt(.routing(count: 0))
        }
        run(outputs: selected, clock: clock, source: driver.uid)
    }

    private func run(outputs: [OutputDevice], clock: OutputDevice, source: String) {
        let key = [clock.uid] + outputs.map(\.uid)
        if key == runningKey, isEngineRunning {
            status = .routing(count: outputs.count)
            return applyParameters()
        }
        guard key != pendingKey else { return } // already starting exactly this
        guard key != failedKey else { return }  // keep the error until something changes

        generation += 1
        let request = generation
        pendingKey = key
        isSlowStart = false
        slowStartTask?.cancel()
        slowStartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.generation == request else { return }
            withAnimation(MenuMetrics.animation) { self.isSlowStart = true }
        }
        isEngineRunning = false
        activeRoutes = []
        activeProbe = nil
        captureLatency = nil
        status = .starting

        engineQueue.async { [engine, weak self] in
            let result = Result { try engine.start(outputs: outputs, clock: clock, source: source) }
                .map { EngineHandle(routes: engine.routes, probe: engine.probe, captureLatency: engine.captureLatency) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.engineStarted(request: request, key: key, count: outputs.count, result: result)
                }
            }
        }
    }

    private func engineStarted(request: Int, key: [String], count: Int, result: Result<EngineHandle, Error>) {
        guard request == generation else { return } // superseded by a newer start or a halt
        // Arrives while the menu may still be animating (an output was just ticked). Applying
        // the resulting UI changes (e.g. "Measure Delays" enabling) without that animation
        // would snap the affected rows to their end positions mid-flight.
        withAnimation(MenuMetrics.animation) {
            finishStart(key: key, count: count, result: result)
        }
    }

    private func finishStart(key: [String], count: Int, result: Result<EngineHandle, Error>) {
        pendingKey = nil
        slowStartTask?.cancel()
        isSlowStart = false
        switch result {
        case .success(let handle):
            failedKey = nil
            runningKey = key
            activeRoutes = handle.routes
            captureLatency = handle.captureLatency
            activeProbe = handle.probe
            isEngineRunning = true
            status = .routing(count: count)
            applyParameters()
        case .failure(let error):
            runningKey = nil
            failedKey = key
            status = .failed(error.localizedDescription)
        }
    }

    private func halt(_ status: Status) {
        generation += 1
        pendingKey = nil
        slowStartTask?.cancel()
        isSlowStart = false
        runningKey = nil
        activeRoutes = []
        activeProbe = nil
        captureLatency = nil
        isEngineRunning = false
        engineQueue.async { [engine] in engine.stop() }
        self.status = status
    }

    /// Master (AudIO's volume/mute, from the driver) × each output's level, applied after
    /// the delay line so changes are heard right away – in software only for outputs without
    /// hardware volume; the others carry it on the device (see `updatePremix`).
    private func applyParameters() {
        let master: Float = isDriverMuted ? 0 : Volume.gain(for: driverVolume)
        activeRoutes.forEach { route in
            let settings = routes[route.uid] ?? RouteSettings()
            let gain = premixed.contains(route.uid) ? 1 : master * Volume.gain(for: settings.level)
            route.set(delayMs: settings.delayMs, gain: gain)
        }
        reportLatency()
    }

    private var reportedLatency: Double?

    /// Tells the driver how late routed audio is heard, so video players delay the picture
    /// by that much (like for AirPods used directly): the slowest output's latency (incl.
    /// Bluetooth, buffers) plus its delay line, plus the capture (see
    /// `Engine.captureLatency`). Speakers that under-report stay off, as they are without
    /// AudIO.
    private func reportLatency() {
        guard let driver else { return }
        let outputs = activeRoutes.compactMap { route in devices.first { $0.uid == route.uid } }
        let slowest = outputs.map { Latency.output(of: $0.id) + (routes[$0.uid]?.delayMs ?? 0) / 1000 }.max()
        let capture = captureLatency ?? 0
        let latency = slowest.map { $0 + capture } ?? 0
        guard abs((reportedLatency ?? -1) - latency) > 0.001 else { return }
        reportedLatency = latency
        Latency.report(latency, to: driver.id)
        latencyLog.notice("reported \(Int(latency * 1000), privacy: .public) ms, capture \(Int(capture * 1000), privacy: .public) ms")
    }

    // MARK: - Volume
    //
    // Every output has its own level; AudIO's own volume is the master. Outputs with a
    // hardware volume get level × master on the device itself ("premixed"), so whenever
    // AudIO stops routing – quit, another output picked in the Sound menu, even a crash –
    // the device already plays exactly as loud as it did through AudIO. (With the cubic
    // volume taper, multiplying the 0…1 values adds their decibels.)

    /// Hardware-volume outputs currently carrying the master.
    private var premixed: Set<String> = []
    /// Hardware volumes AudIO last wrote – any other reported value was changed on the
    /// device itself (its buttons, another app).
    private var writtenVolumes: [String: Double] = [:]
    private var lastWrites: [String: Date] = [:]
    private var isUpdatingPremix = false

    private var effectiveMaster: Double { isDriverMuted ? 0 : driverVolume }

    /// Premixes every routed hardware-volume output. One joining adopts its level from its
    /// current volume, so switching to AudIO doesn't change the loudness either.
    private func updatePremix() {
        guard !isUpdatingPremix else { return }
        isUpdatingPremix = true
        defer { isUpdatingPremix = false }

        let targets = isDriverActive
            ? Set(selectedDevices.filter(\.hasVolumeControl).map(\.uid))
            : []
        for uid in targets.subtracting(premixed) { adoptLevel(of: uid) }
        // Deselected while routing: back to its own level. When AudIO stops routing the
        // premixed volumes stay – that's the hand-over.
        if isDriverActive {
            for uid in premixed.subtracting(targets) {
                guard let device = devices.first(where: { $0.uid == uid }) else { continue }
                write(routes[uid]?.level ?? 1, to: device)
                if Volume.canMute(device.id) { Volume.setMuted(false, on: device.id) }
            }
        }
        premixed = targets
        pushHardwareVolumes()
        // Adopting a level above re-entered reconcile while `premixed` was still the old set –
        // a running engine got the master in software on top of the hardware. Re-apply.
        applyParameters()
    }

    private func adoptLevel(of uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }),
              let volume = Volume.read(device.id), effectiveMaster > 0.01 else { return }
        routes[uid, default: RouteSettings()].level = min(volume / effectiveMaster, 1)
    }

    /// Level × master onto every premixed output (mute as mute where the device has one).
    private func pushHardwareVolumes() {
        for uid in premixed {
            guard let device = devices.first(where: { $0.uid == uid }) else { continue }
            let canMute = Volume.canMute(device.id)
            let volume = isDriverMuted && !canMute ? 0 : (routes[uid]?.level ?? 1) * driverVolume
            write(volume, to: device)
            if canMute, Volume.isMuted(device.id) != isDriverMuted {
                Volume.setMuted(isDriverMuted, on: device.id)
            }
        }
    }

    private func write(_ volume: Double, to device: OutputDevice) {
        let volume = volume.clamped01
        guard abs((writtenVolumes[device.uid] ?? -1) - volume) > 0.001 else { return }
        writtenVolumes[device.uid] = volume
        lastWrites[device.uid] = Date()
        Volume.write(volume, to: device.id)
    }

    /// A premixed output's volume changed on the device itself: that becomes its level –
    /// or, beyond the master, the master (with a single output its buttons act as the master).
    private func hardwareVolumeChanged(_ device: OutputDevice) {
        // Our own writes echo back – Bluetooth devices round them to their few volume steps,
        // so compare loosely and ignore reports right after a write.
        guard premixed.contains(device.uid), let volume = Volume.read(device.id),
              abs((writtenVolumes[device.uid] ?? -1) - volume) > 0.02,
              Date().timeIntervalSince(lastWrites[device.uid] ?? .distantPast) > 0.75 else { return }
        writtenVolumes[device.uid] = volume
        guard !isDriverMuted else { return }
        if volume <= driverVolume, driverVolume > 0.01 {
            routes[device.uid, default: RouteSettings()].level = volume / driverVolume
        } else if let driver {
            routes[device.uid, default: RouteSettings()].level = 1
            driverVolume = volume
            Volume.write(volume, to: driver.id) // other outputs follow via the listener
        }
    }

    private func observeVolumes() {
        let deviceListeners = devices.filter(\.hasVolumeControl).compactMap { device in
            PropertyListener(object: device.id, address: Volume.main) { [weak self] in
                MainActor.assumeIsolated { self?.hardwareVolumeChanged(device) }
            }
        }
        let driverListeners = driver.map { driver in
            [Volume.main, Volume.mute].filter(driver.id.has).compactMap { address in
                PropertyListener(object: driver.id, address: address) { [weak self] in
                    MainActor.assumeIsolated { self?.syncDriverVolume() }
                }
            }
        } ?? []
        volumeListeners = deviceListeners + driverListeners
    }

    private func syncDriverVolume() {
        guard let driver else { return }
        driverVolume = Volume.read(driver.id) ?? 1
        isDriverMuted = Volume.isMuted(driver.id)
        applyParameters()
        pushHardwareVolumes()
    }
}

/// What the engine queue hands to the main thread after a successful start.
private struct EngineHandle: @unchecked Sendable {
    let routes: [Route]
    let probe: Probe?
    let captureLatency: Double
}
