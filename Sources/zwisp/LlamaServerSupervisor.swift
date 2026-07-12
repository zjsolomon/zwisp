import Darwin
import Foundation
import ZwispCore

/// Thread-safe holder of the cleanup server's current localhost address.
/// Shared between the supervisor (which may slide to a neighbouring port when
/// the configured one is squatted) and the `LlamaServerClient` base-URL
/// closure, which is called from non-main contexts on every request.
final class LlamaServerAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int

    init(port: Int) {
        self.port = port
    }

    var url: URL {
        lock.lock(); defer { lock.unlock() }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    var currentPort: Int {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    func update(port: Int) {
        lock.lock(); defer { lock.unlock() }
        self.port = port
    }
}

/// Owns the llama-server bundled inside zwisp.app: spawn it against the
/// downloaded model, wait for `/health`, restart it (bounded) if it dies, and
/// take it down with the app. The subprocess boundary is deliberate — an
/// engine crash must never take dictation with it, and the model stays
/// resident (a stronger `keep_alive -1` than Ollama ever gave us).
///
/// `@MainActor` because it mutates state the app reads on the main thread;
/// the child's pipe and termination callbacks hop back here.
@MainActor
final class LlamaServerSupervisor {
    private let config: Configuration.Cleanup
    let address: LlamaServerAddress
    private var process: Process?
    private var modelPath: URL?
    /// Set by `terminate()` so the termination handler can tell a deliberate
    /// shutdown from a crash.
    private var deliberateStop = false
    private var startedAt = Date.distantPast
    /// Instant-exit retries (port squatters) and crash restarts, both bounded —
    /// a server that can't stay up must degrade to raw-only dictation, not
    /// respawn forever.
    private var portRetries = 0
    private var crashRestarts = 0

    /// Fired whenever the server's reachability may have changed (healthy,
    /// exited, gave up) so the app can re-derive the menu-bar cleanup status.
    var onStateChange: (() -> Void)?

    init(config: Configuration.Cleanup, address: LlamaServerAddress) {
        self.config = config
        self.address = address
    }

    /// Launches the bundled server against `modelPath`. No-op while a child is
    /// already running. Missing binary (a bare `swift build` binary run outside
    /// the .app bundle) just logs — cleanup stays raw-only, dictation works.
    func start(modelPath: URL) {
        guard process == nil else { return }
        guard let binary = Self.bundledServerURL() else {
            Log.write("llama-server: bundled binary not found (running outside the .app?); cleanup engine unavailable")
            return
        }
        deliberateStop = false
        self.modelPath = modelPath
        sweepStaleInstance()
        launch(binary: binary, modelPath: modelPath)
    }

    /// Deliberate shutdown (app quit). The server holds ~3 GB resident; it must
    /// not outlive zwisp.
    func terminate() {
        deliberateStop = true
        process?.terminate()
        process = nil
        removePidfile()
    }

    /// The server binary inside the bundle, or `nil` when absent/not executable.
    static func bundledServerURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("llama/llama-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Launch

    private func launch(binary: URL, modelPath: URL) {
        let port = address.currentPort
        let child = Process()
        child.executableURL = binary
        child.arguments = config.server.arguments(modelPath: modelPath.path, port: port)

        // Surface only warnings/errors from the child's chatter — llama-server
        // logs every request, which would drown the dictation log this file
        // exists to keep readable.
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                if line.contains(" E ") || line.lowercased().contains("error") {
                    Log.write("llama-server: \(line)")
                }
            }
        }

        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processEnded(status: status) }
            }
        }

        do {
            try child.run()
        } catch {
            Log.write("llama-server: failed to launch — \(error.localizedDescription)")
            return
        }
        startedAt = Date()
        process = child
        writePidfile(child.processIdentifier)
        Log.write("llama-server: launched (pid \(child.processIdentifier), port \(port))")
        Task { await waitForHealth() }
    }

    private func processEnded(status: Int32) {
        process = nil
        removePidfile()
        defer { onStateChange?() }
        guard !deliberateStop else { return }
        guard let binary = Self.bundledServerURL(), let modelPath else { return }

        if Date().timeIntervalSince(startedAt) < 3, portRetries < 4 {
            // Died within moments of launching — almost certainly the port.
            // Slide to the next one; the shared address keeps the client in step.
            portRetries += 1
            address.update(port: config.server.port + portRetries)
            Log.write("llama-server: exited instantly (status \(status)); retrying on port \(address.currentPort)")
            launch(binary: binary, modelPath: modelPath)
        } else if crashRestarts < 3 {
            crashRestarts += 1
            let delay = pow(2.0, Double(crashRestarts))   // 2s, 4s, 8s
            Log.write("llama-server: exited (status \(status)); restart \(crashRestarts)/3 in \(Int(delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.process == nil, !self.deliberateStop else { return }
                    self.launch(binary: binary, modelPath: modelPath)
                }
            }
        } else {
            Log.write("llama-server: giving up after repeated exits; dictation continues raw-only")
        }
    }

    /// Polls `/health` until the model is loaded (llama-server answers 503
    /// while loading), then lets the app re-derive status — which warms the
    /// prompt cache off the unavailable→active transition.
    private func waitForHealth() async {
        let deadline = Date().addingTimeInterval(config.server.startTimeout)
        let launched = startedAt
        while Date() < deadline {
            guard process != nil, startedAt == launched else { return }  // exited or relaunched
            var request = URLRequest(url: address.url.appendingPathComponent("health"))
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               LlamaServerClient.parseHealth(data: data, response: response) {
                crashRestarts = 0   // a healthy run earns back its restart budget
                Log.write(String(format: "llama-server: healthy in %.1fs",
                                 Date().timeIntervalSince(launched)))
                onStateChange?()
                return
            }
            try? await Task.sleep(
                nanoseconds: UInt64(config.server.healthPollInterval * 1_000_000_000))
        }
        Log.write("llama-server: not healthy after \(Int(config.server.startTimeout))s; cleanup stays raw-only")
        onStateChange?()
    }

    // MARK: - Stale-instance sweep

    /// If a previous zwisp crashed, its server may still be running (and
    /// holding the port + ~3 GB). The pidfile names it; kill it only after
    /// confirming the pid still points at a llama-server executable, so a
    /// recycled pid can never take down an innocent process.
    private func sweepStaleInstance() {
        guard let text = try? String(contentsOf: Self.pidfileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        removePidfile()
        guard kill(pid, 0) == 0 else { return }   // long gone
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0,
              String(cString: buffer).hasSuffix("llama-server") else { return }
        Log.write("llama-server: terminating stale instance from a previous run (pid \(pid))")
        kill(pid, SIGTERM)
    }

    private static let pidfileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("zwisp/llama-server.pid")

    private func writePidfile(_ pid: Int32) {
        let url = Self.pidfileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePidfile() {
        try? FileManager.default.removeItem(at: Self.pidfileURL)
    }
}
