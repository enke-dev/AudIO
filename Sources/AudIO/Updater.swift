import AppKit
import Security
import SwiftUI

/// Updates from GitHub releases – no API and no feed: `releases/latest` redirects to the
/// newest release's tag, and its disk image has a predictable name (`scripts/release.sh`).
/// Plain github.com pages aren't subject to the REST API's rate limit.
///
/// Checks on launch and once a day (while enabled), offers "Update to x.y.z" next to the
/// title, then downloads the image, verifies the new app is signed with the same
/// certificate, swaps the bundle in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case available(String)
        case updating
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if isEnabled { check() } else if case .available = state { state = .idle }
        }
    }

    private enum Key {
        static let enabled = "checkForUpdates"
        static let lastCheck = "lastUpdateCheck"
    }

    private nonisolated static let repository = URL(string: "https://github.com/enke-dev/AudIO")!
    private static let interval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    init() {
        defaults.register(defaults: [Key.enabled: true])
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    /// Checks now, then whenever a day has passed (hourly tick – survives sleep).
    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let last = self.defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
                if Date().timeIntervalSince(last) >= Self.interval { self.check() }
            }
        }
        timer?.tolerance = 5 * 60
    }

    func check() {
        // Local builds are 0.0.0 (CI stamps the version) – nothing to compare against.
        guard isEnabled, current != "0.0.0", state != .updating else { return }
        defaults.set(Date(), forKey: Key.lastCheck)
        Task {
            guard let latest = try? await Self.latestVersion(),
                  Version(latest) > Version(current) else { return }
            withAnimation(MenuMetrics.animation) { state = .available(latest) }
        }
    }

    func install() {
        guard case .available(let version) = state else { return }
        withAnimation(MenuMetrics.animation) { state = .updating }
        let target = Bundle.main.bundleURL
        Task {
            do {
                try await Task.detached { try await Self.replace(target, with: version) }.value
                Self.relaunch(target)
            } catch {
                withAnimation(MenuMetrics.animation) { state = .failed(error.localizedDescription) }
            }
        }
    }

    /// After a failed update: offer it again.
    func retry() {
        withAnimation(MenuMetrics.animation) { state = .idle }
        check()
    }

    // MARK: - Steps

    /// The tag `releases/latest` redirects to, without the "v".
    private nonisolated static func latestVersion() async throws -> String? {
        var request = URLRequest(url: repository.appending(path: "releases/latest"))
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let url = response.url, url.pathComponents.dropLast().last == "tag" else { return nil }
        let tag = url.lastPathComponent
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : nil
    }

    private nonisolated static func replace(_ target: URL, with version: String) async throws {
        let dmgURL = repository.appending(path: "releases/download/v\(version)/AudIO-\(version).dmg")
        let (download, response) = try await URLSession.shared.download(from: dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Couldn’t download AudIO \(version).")
        }

        let files = FileManager.default
        // Temporary folder on the app's volume, so the final swap is a rename.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }
        let dmg = work.appending(path: "AudIO.dmg")
        try files.moveItem(at: download, to: dmg)

        let mount = work.appending(path: "mount")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path, dmg.path)
        defer { try? run("/usr/bin/hdiutil", "detach", "-force", "-quiet", mount.path) }

        let staged = work.appending(path: "AudIO.app")
        try files.copyItem(at: mount.appending(path: "AudIO.app"), to: staged)
        try verifySignature(of: staged)
        _ = try files.replaceItemAt(target, withItemAt: staged)
    }

    /// The new app must satisfy this app's designated requirement – same bundle ID, same
    /// certificate. Skipped for ad-hoc builds (their requirement is the exact code hash).
    private nonisolated static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else { return }

        var info: CFDictionary?
        SecCodeCopySigningInformation(selfStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return }

        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode,
              SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess
        else { throw UpdateError("The downloaded app isn’t signed like this one – not installed.") }
    }

    /// Opens the (new) app once this process has exited, then quits.
    private static func relaunch(_ app: URL) {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Numeric "major.minor.patch" comparison.
private struct Version: Comparable {
    let parts: [Int]
    init(_ string: String) { parts = string.split(separator: ".").map { Int($0) ?? 0 } }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        let pad = { (parts: [Int]) in parts + Array(repeating: 0, count: count - parts.count) }
        return pad(lhs.parts).lexicographicallyPrecedes(pad(rhs.parts))
    }
}
