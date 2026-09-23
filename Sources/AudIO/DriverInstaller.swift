import Foundation

/// Installs the driver bundled inside the app into /Library/Audio/Plug-Ins/HAL – the only
/// place Core Audio loads drivers from – using the standard macOS administrator prompt,
/// then restarts Core Audio so the "AudIO" device appears.
enum DriverInstaller {
    enum State: Equatable {
        /// No driver in this build (e.g. `swift run` from the package).
        case unavailable
        case notInstalled
        /// An older driver version is installed.
        case outdated
        case current
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let installURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AudIO.driver")

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "AudIO", withExtension: "driver")
    }

    static var state: State {
        guard let bundled = bundledURL else { return .unavailable }
        guard let installed = version(at: installURL) else { return .notInstalled }
        guard let available = version(at: bundled) else { return .current }
        return installed.compare(available, options: .numeric) == .orderedAscending ? .outdated : .current
    }

    static func install() async throws {
        guard let source = bundledURL else { throw Failure(message: "This build has no bundled driver") }
        let target = quoted(installURL.path)
        // Copied from a downloaded app, the driver carries the quarantine flag – strip it,
        // or Core Audio won't load the (ad-hoc signed) bundle.
        try await runAsAdministrator("""
            mkdir -p /Library/Audio/Plug-Ins/HAL && \
            rm -rf \(target) && \
            cp -R \(quoted(source.path)) \(target) && \
            (xattr -dr com.apple.quarantine \(target) 2>/dev/null; true) && \
            chown -R root:wheel \(target) && \
            (killall coreaudiod; true)
            """)
    }

    /// Waits (off the main thread – HAL calls block while coreaudiod restarts) until the
    /// AudIO device is published, or gives up after `timeout`.
    static func waitForDevice(timeout: Duration = .seconds(15)) async {
        await Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now + timeout
            try? await Task.sleep(for: .milliseconds(500))
            while ContinuousClock.now < deadline {
                if Devices.virtualDevice() != nil { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }.value
    }

    // MARK: - Helpers

    /// Reads the version straight from disk – `Bundle` caches Info.plist contents.
    private static func version(at url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `do shell script … with administrator privileges` shows the system password prompt.
    /// Cancelling it throws `CancellationError`.
    private static func runAsAdministrator(_ command: String) async throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else { return continuation.resume() }
                let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: output.contains("-128") ? CancellationError() : Failure(message: output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
