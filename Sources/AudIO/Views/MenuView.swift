import AppKit
import ServiceManagement
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var router: Router
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if router.driver != nil {
                masterVolume.disabled(!isReady)
            }
            Divider()
            if router.devices.isEmpty {
                Text("No output devices found").foregroundStyle(.secondary)
            }
            Group {
                ForEach(router.devices) { device in
                    DeviceRow(
                        device: device,
                        isSystemOutput: device.uid == router.defaultOutputUID,
                        showsID: duplicateNames.contains(device.name),
                        settings: router.binding(for: device.uid),
                        volume: router.volumeBinding(for: device.uid)
                    )
                }
                Divider()
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            .disabled(!isReady)
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AudIO").font(.headline)
                if let notice {
                    Text(notice.text)
                        .font(.caption)
                        .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // Selecting "AudIO" as sound output is the switch; buttons only for what's missing.
            if router.isInstallingDriver {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let title = driverButtonTitle {
                Button(title) { router.installDriver() }
                    .disabled(router.driverState == .unavailable)
                    .help("Adds “AudIO” as a sound output – asks for your password")
            } else if router.driver != nil, !router.isDriverActive {
                Button("Use AudIO") { router.activate() }
                    .help("Selects “AudIO” as sound output – same as picking it in the Sound menu")
            }
        }
    }

    /// AudIO's own volume (driver mode): the volume keys and the Sound menu control it too.
    private var masterVolume: some View {
        HStack(spacing: 8) {
            Image(systemName: router.isDriverMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: router.driverVolumeBinding(), in: 0...1)
                .controlSize(.small)
            Text("\(Int((router.driverVolume * 100).rounded())) %")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button("Measure delays") { router.measureDelays() }
                .disabled(!isReady || !router.canMeasure)
                .help("Plays a short test tone on each selected output and measures when it arrives")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// Names shared by several devices (e.g. two identical displays) get their ID shown.
    private var duplicateNames: Set<String> {
        let counts = router.devices.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Everything but Quit needs the driver, selected as sound output (and no install running).
    private var isReady: Bool {
        router.driver != nil && router.isDriverActive && !router.isInstallingDriver
    }

    private var driverButtonTitle: String? {
        switch router.driverState {
        case .notInstalled, .unavailable: router.driver == nil ? "Install audio device" : nil
        case .outdated: "Update audio device"
        case .current: nil
        }
    }

    /// Only things that need attention: errors and a running measurement.
    private var notice: (text: String, isError: Bool)? {
        if let error = router.driverError { return (error, true) }
        return switch (router.calibration, router.status) {
        case (.measuring(let text), _): (text, false)
        case (.failed(let text), _): (text, true)
        case (_, .failed(let text)): (text, true)
        case (_, .starting): ("Starting… if macOS asks, allow system audio recording", false)
        default: nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            launchAtLogin = service.status == .enabled
        }
    }
}
