import AppKit
import CryptoKit
import FtopCore
import os

/// Looks for a newer release and replaces the installed app with it.
///
/// Only the app bundle the panel runs from is replaced. The setuid helper that
/// `sudo ftop grant` installed is outside the bundle and is never touched, so an
/// update cannot change what runs as root.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(AppVersion)
        case installing(AppVersion)
        case failed(String)
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
    var mode = UpdateMode.install
    /// Called just before the app quits to restart into the new version.
    var willRelaunch: (() -> Void)?

    private var found: ReleaseInfo?
    private var busy = false
    private let log = Logger(subsystem: "dev.ftop", category: "update")
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The version of the running app; nil when it was not started from an app bundle.
    static let current: AppVersion? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)

    /// Only an installed `Ftop.app` the user may write to can replace itself.
    static var canInstall: Bool {
        let bundle = Bundle.main.bundleURL
        return current != nil && bundle.pathExtension == "app" && Bundle.main.bundleIdentifier == "dev.ftop.app"
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// The daily check: does nothing when updates are off or the last check is recent.
    func checkIfDue() {
        guard mode != .off, Self.current != nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else { return }
        Task { await check(install: mode == .install) }
    }

    /// Asks the release server now. `install` also installs what it finds.
    func check(install: Bool) async {
        guard !busy, let current = Self.current else { return }
        busy = true
        defer { busy = false }
        state = .checking
        do {
            var request = URLRequest(url: UpdateFeed.latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure("the release server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let release = UpdateFeed.release(from: data) else { throw Failure("the latest release has no archive ftop can install") }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            guard release.version > current else {
                found = nil
                state = .upToDate
                return
            }
            found = release
            state = .available(release.version)
            if install, Self.canInstall { try await self.install(release) }
        } catch {
            fail(error)
        }
    }

    /// Installs the release the last check found.
    func installFound() {
        guard let found, !busy, Self.canInstall else { return }
        Task {
            busy = true
            defer { busy = false }
            do { try await install(found) } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        let reason = (error as? Failure)?.reason ?? error.localizedDescription
        log.error("update failed: \(reason, privacy: .public)")
        state = .failed(reason)
    }

    private func install(_ release: ReleaseInfo) async throws {
        state = .installing(release.version)
        let manager = FileManager.default
        let target = Bundle.main.bundleURL
        // Next to the installed app, so the final swap stays on one volume.
        let work = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? manager.removeItem(at: work) }

        let (downloaded, response) = try await Self.session.download(from: release.archive)
        let archive = work.appending(path: "update.zip")
        try manager.moveItem(at: downloaded, to: archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download answered \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure("the downloaded archive does not match the checksum of the release") }
        }

        let unpacked = work.appending(path: "unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let app = unpacked.appending(path: "Ftop.app")
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
            info["CFBundleIdentifier"] as? String == "dev.ftop.app",
            (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == release.version
        else { throw Failure("the archive does not hold ftop \(release.version)") }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        _ = try manager.replaceItemAt(target, withItemAt: app)
        log.info("installed \(release.version.description, privacy: .public), restarting")
        try relaunch(target)
    }

    /// Starts the new copy once this one has gone; two panels never run together.
    private func relaunch(_ bundle: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n -g -a \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier), bundle.path,
        ]
        try task.run()
        willRelaunch?()
        NSApp.terminate(nil)
    }

    private struct Failure: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// No cookies, no cache, nothing kept on disk.
    private static let session = URLSession(configuration: .ephemeral)

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw Failure("\(tool) failed with status \(task.terminationStatus)") }
        }.value
    }
}
