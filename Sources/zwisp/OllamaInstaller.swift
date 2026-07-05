import AppKit
import Foundation
import ZwispCore

/// Owns the optional AI-cleanup dependency chain: install the Ollama app if
/// missing, start its local server, and pull the recommended cleanup model —
/// each with visible progress in the setup window. This is the automation that
/// didn't exist before; `AppDelegate.startOllama` only ever *launched* an
/// already-installed copy.
///
/// A `@MainActor` class because it drives two UI phases. The heavy lifting
/// (network download, `ditto`/`codesign` subprocesses, the pull stream) runs
/// off-main and hops its results back here; the main actor only ever mutates
/// `appPhase`/`modelPhase` and fires the callbacks.
///
/// Security posture (deliberate — see plan): the downloaded app must pass
/// `codesign --verify --deep --strict` AND carry an expected bundle ID before
/// we ever launch it. We never strip quarantine and never touch `spctl`.
@MainActor
final class OllamaInstaller {
    /// Ollama's local server is reachable. Reachability is the whole truth —
    /// a Homebrew `ollama serve` has no app bundle anywhere, so requiring one
    /// here would call a perfectly working install "missing". Disk presence
    /// only matters when the server is DOWN, to pick the repair action
    /// (start vs install) — see `serverToolOnDisk()`.
    private(set) var appPhase: InstallPhase = .missing
    /// The recommended cleanup model (`cleanup.model`) is in `/api/tags`.
    private(set) var modelPhase: InstallPhase = .missing

    /// Fired on every phase change so the setup window can re-render.
    var onPhaseChange: (() -> Void)?
    /// Fired once when the cleanup model finishes pulling — the app re-warms
    /// cleanup off this (a freshly available model wants its KV cache primed).
    var onCleanupModelReady: (() -> Void)?

    private let cleanup: CleanupService
    private let setup: Configuration.Setup

    /// Fresh per attempt; throttles the two high-frequency progress sources.
    private var downloadGate = ProgressGate()
    private var pullGate = ProgressGate()

    init(cleanup: CleanupService, setup: Configuration.Setup) {
        self.cleanup = cleanup
        self.setup = setup
    }

    // MARK: - Detection

    /// The installed Ollama.app, or `nil`. Absorbs `AppDelegate.startOllama`'s
    /// lookup: Launch Services by bundle ID first (catches copies anywhere),
    /// then the two conventional install locations.
    func installedAppURL() -> URL? {
        for id in setup.ollamaBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        if let url = Self.existingURL("/Applications/Ollama.app") { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Ollama.app")
        return Self.existingURL(home.path)
    }

    /// Re-derives both phases from reality: the app bundle on disk, whether the
    /// server answers `/api/tags` (`availableModels() != nil`), and whether the
    /// recommended model is listed. Reality wins — a stale `.failed` clears once
    /// the truth is re-read. NO-OP while a chain is running so it can't clobber
    /// live progress. (`onCleanupModelReady` is intentionally NOT fired here;
    /// only the pull chain triggers a re-warm.)
    func refreshDetection() async {
        guard !appPhase.isBusy, !modelPhase.isBusy else { return }
        let models = await cleanup.availableModels()  // nil ⇒ server unreachable

        // A reachable server IS an installed Ollama, however it got here —
        // app bundle, Homebrew CLI, hand-built. Never require a .app on disk.
        appPhase = (models != nil) ? .installed : .missing
        modelPhase = (models?.contains(cleanup.model) == true) ? .installed : .missing
        onPhaseChange?()
    }

    /// Is Ollama present on disk in ANY form — app bundle or CLI binary?
    /// Drives the repair action when the server is down: on-disk means "start
    /// it", absent means "install it". (Reachability, not this, decides the
    /// `appPhase` — see `refreshDetection`.)
    func serverToolOnDisk() -> Bool {
        installedAppURL() != nil || Self.cliURL() != nil
    }

    // MARK: - Setup chain

    /// Runs only the missing steps, in order: install the app → launch + wait
    /// for the server → pull the model. A no-op if either phase is already busy
    /// (the button that calls this is hidden while busy, but guard anyway so a
    /// double-tap can't launch two chains).
    func runSetupChain() {
        guard !appPhase.isBusy, !modelPhase.isBusy else { return }
        Task { await runChain() }
    }

    private func runChain() async {
        // 1. Install the app bundle only when NO copy of Ollama exists on disk
        //    — a Homebrew CLI install counts (launchServer knows how to start
        //    it); installing Ollama.app alongside it would just duplicate.
        if !serverToolOnDisk() {
            do {
                try await installAppBundle()
            } catch let error as InstallError {
                setAppPhase(.failed(error.message))
                return
            } catch {
                setAppPhase(.failed(error.localizedDescription))
                return
            }
        }

        // 2. Ensure the server is reachable (launch + poll), unless it already is.
        if await cleanup.availableModels() == nil {
            setAppPhase(.installing(stage: "Starting Ollama", fraction: nil))
            Log.write("ollama install: launching server")
            launchServer()
            guard await waitForServer() else {
                setAppPhase(.failed("Ollama didn't start — open it from Applications, then retry"))
                return
            }
        }
        setAppPhase(.installed)

        // 3. Pull the cleanup model if it's missing.
        if await cleanup.availableModels()?.contains(cleanup.model) == true {
            setModelPhase(.installed)
            onCleanupModelReady?()
            return
        }
        await pullCleanupModel()
    }

    /// Launches Ollama's local server. Absorbs `startOllama`'s launch strategies:
    /// open the app bundle in the background (it also registers a login item and
    /// starts the HTTP server itself), else fall back to the Homebrew CLI's
    /// `ollama serve`, fully detached so the server outlives zwisp.
    func launchServer() {
        if let appURL = installedAppURL() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false  // background server; don't steal focus
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            Log.write("launched Ollama.app at \(appURL.path)")
            return
        }
        if let cli = Self.cliURL() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "nohup \(cli.path) serve >/dev/null 2>&1 &"]
            do {
                try process.run()
                Log.write("started '\(cli.path) serve' (detached)")
            } catch {
                Log.write("failed to start ollama serve: \(error)")
            }
            return
        }
        Log.write("launchServer: no Ollama.app or CLI found")
    }

    // MARK: - Install chain steps

    /// Download → unpack → verify → install. Runs the whole app-bundle install
    /// inside a scratch directory that's removed on *every* exit (success,
    /// throw, verify-fail), so a failed attempt leaves nothing behind. Each step
    /// advances `appPhase` and throws an `InstallError` (human message) on
    /// failure.
    private func installAppBundle() async throws {
        if let shortfall = cleanupDiskShortfall() {
            throw InstallError(message: shortfall)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zwisp-ollama-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Download.
        downloadGate = ProgressGate()
        setAppPhase(.installing(stage: "Downloading Ollama", fraction: 0))
        Log.write("ollama install: downloading from \(setup.ollamaDownloadURL.absoluteString)")
        let zip = try await downloadZip(into: scratch)

        // Unpack — `ditto -xk` (NOT unzip) so the app's code signature survives.
        setAppPhase(.installing(stage: "Unpacking Ollama", fraction: nil))
        Log.write("ollama install: unpacking")
        let extracted = scratch.appendingPathComponent("extracted")
        do {
            try await Self.runProcess("/usr/bin/ditto", ["-xk", zip.path, extracted.path])
        } catch {
            throw InstallError(message: "Couldn't unpack the Ollama download")
        }
        let app = try locateApp(in: extracted)

        // Verify signature + bundle ID before we trust the app.
        setAppPhase(.installing(stage: "Verifying Ollama", fraction: nil))
        Log.write("ollama install: verifying signature")
        try await verifySignature(of: app)

        // Move into /Applications (or ~/Applications).
        setAppPhase(.installing(stage: "Installing Ollama", fraction: nil))
        let installed = try installIntoApplications(app)
        Log.write("ollama install: installed at \(installed.path)")
    }

    /// Downloads the zip to a throttled progress bar and returns its path inside
    /// `scratch`. The async `download(for:delegate:)` deletes the temp file the
    /// instant it returns, so we move it into scratch immediately.
    private func downloadZip(into scratch: URL) async throws -> URL {
        let delegate = DownloadProgressDelegate { [weak self] fraction in
            // Fires off-main on URLSession's delegate queue; hop + throttle.
            Task { @MainActor in
                guard let self else { return }
                guard self.downloadGate.shouldEmit(fraction) else { return }
                self.setAppPhase(.installing(stage: "Downloading Ollama", fraction: fraction))
            }
        }
        let request = URLRequest(url: setup.ollamaDownloadURL)
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        } catch {
            throw InstallError(message: "Couldn't download Ollama — check your connection and retry")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InstallError(message: "Couldn't download Ollama (HTTP \(code))")
        }
        let zip = scratch.appendingPathComponent("Ollama-darwin.zip")
        do {
            try FileManager.default.moveItem(at: tempURL, to: zip)
        } catch {
            throw InstallError(message: "Couldn't save the Ollama download")
        }
        return zip
    }

    /// Finds `Ollama.app` at the extraction root, with a one-level shallow-scan
    /// fallback for a zip that nests it inside a folder.
    private func locateApp(in extracted: URL) throws -> URL {
        let fm = FileManager.default
        let direct = extracted.appendingPathComponent("Ollama.app")
        if fm.fileExists(atPath: direct.path) { return direct }
        if let entries = try? fm.contentsOfDirectory(
            at: extracted, includingPropertiesForKeys: nil) {
            for entry in entries {
                if entry.lastPathComponent == "Ollama.app" { return entry }
                let nested = entry.appendingPathComponent("Ollama.app")
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }
        throw InstallError(message: "Downloaded Ollama failed verification")
    }

    /// `codesign --verify --deep --strict` must pass AND the bundle ID must be
    /// one we expect. Either failure is the same user-facing verdict.
    private func verifySignature(of app: URL) async throws {
        do {
            try await Self.runProcess(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw InstallError(message: "Downloaded Ollama failed verification")
        }
        guard let id = Bundle(url: app)?.bundleIdentifier,
              setup.ollamaBundleIDs.contains(id) else {
            throw InstallError(message: "Downloaded Ollama failed verification")
        }
    }

    /// Moves the verified app into `/Applications` when writable, else
    /// `~/Applications` (created if needed). Removes any stale existing copy at
    /// the destination first so the move can't fail on a pre-existing bundle.
    private func installIntoApplications(_ app: URL) throws -> URL {
        let fm = FileManager.default
        let appsDir: URL
        if fm.isWritableFile(atPath: "/Applications") {
            appsDir = URL(fileURLWithPath: "/Applications")
        } else {
            appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        }
        let dest = appsDir.appendingPathComponent("Ollama.app")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: app, to: dest)
        return dest
    }

    /// Polls `availableModels() != nil` every `ollamaServerPollInterval` until
    /// the server answers or `ollamaServerStartTimeout` elapses.
    private func waitForServer() async -> Bool {
        let deadline = Date().addingTimeInterval(setup.ollamaServerStartTimeout)
        while Date() < deadline {
            if await cleanup.availableModels() != nil { return true }
            try? await Task.sleep(
                nanoseconds: UInt64(setup.ollamaServerPollInterval * 1_000_000_000))
        }
        return await cleanup.availableModels() != nil
    }

    /// Streams the model pull, mapping its progress into `modelPhase` and its
    /// terminal `PullError` into a human message. On success fires
    /// `onCleanupModelReady`.
    private func pullCleanupModel() async {
        let name = cleanup.model
        pullGate = ProgressGate()
        setModelPhase(.installing(stage: "Downloading \(name)", fraction: 0))
        Log.write("ollama install: pulling model \(name)")
        do {
            try await cleanup.pullModel(name) { [weak self] _, fraction in
                // @Sendable, fires off the pull reader task; hop + throttle.
                Task { @MainActor in
                    guard let self else { return }
                    if let fraction, !self.pullGate.shouldEmit(fraction) { return }
                    self.setModelPhase(.installing(
                        stage: "Downloading \(name)", fraction: fraction))
                }
            }
            setModelPhase(.installed)
            Log.write("ollama install: model \(name) ready")
            onCleanupModelReady?()
        } catch {
            let message = Self.pullFailureMessage(error)
            setModelPhase(.failed(message))
            Log.write("ollama install: pull failed — \(message)")
        }
    }

    // MARK: - Helpers

    private func setAppPhase(_ new: InstallPhase) {
        appPhase = new
        onPhaseChange?()
    }

    private func setModelPhase(_ new: InstallPhase) {
        modelPhase = new
        onPhaseChange?()
    }

    /// The exact 6 GB message when the home volume is short on space, else `nil`.
    /// A probe failure is treated as "enough" — don't block on an unreadable
    /// volume.
    private func cleanupDiskShortfall() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        guard available < setup.minFreeBytesForCleanupSetup else { return nil }
        return "Not enough free disk space — about 6 GB needed"
    }

    private static func pullFailureMessage(_ error: Error) -> String {
        guard let pullError = error as? CleanupService.PullError else {
            return error.localizedDescription
        }
        switch pullError {
        case .unreachable:
            return "Lost the connection to Ollama during the download — retry"
        case .badStatus(let code):
            return "Ollama rejected the download (HTTP \(code))"
        case .server(let message):
            return message
        case .truncated:
            return "The download ended early — retry to finish it"
        }
    }

    private static func existingURL(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// The Homebrew/manual CLI install, if any (Apple Silicon and Intel paths).
    private static func cliURL() -> URL? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    /// A short human message wrapping either an install-step failure.
    private struct InstallError: Error {
        let message: String
    }

    /// Runs a command-line tool off-main and resolves when it exits, throwing
    /// with captured stderr on a non-zero status. `Process`'s termination
    /// handler fires on a background queue, so the main actor is never blocked
    /// waiting for `ditto`/`codesign`.
    private nonisolated static func runProcess(_ launchPath: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()  // discard tool chatter
            process.terminationHandler = { finished in
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ProcessError.nonzero(
                        status: finished.terminationStatus, stderr: stderr))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private enum ProcessError: Error {
        case nonzero(status: Int32, stderr: String)
    }
}

/// Forwards `URLSessionDownloadTask` byte progress as a 0…1 fraction. A tiny
/// task-specific delegate for `download(for:delegate:)`; the async call itself
/// consumes the finished file, so `didFinishDownloadingTo` is a required no-op.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }  // unknown length ⇒ indeterminate
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
