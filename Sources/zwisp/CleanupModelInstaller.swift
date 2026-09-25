import CryptoKit
import Foundation
import ZwispCore

/// Owns the download of the bundled cleanup engine's one model file — a single
/// pinned GGUF fetched with visible progress into Application Support, then
/// verified by size and SHA-256 before anything ever serves it. Mirrors
/// `SpeechModelInstaller`: a `@MainActor` class whose `phase` drives the setup
/// window, with `onPhaseChange` firing on every change.
@MainActor
final class CleanupModelInstaller {
    /// Where this install currently stands. UI reads it; only this class writes
    /// it (always on the main actor), firing `onPhaseChange` on every change.
    private(set) var phase: InstallPhase = .missing

    /// Fired after every `phase` change so the setup window can re-render.
    var onPhaseChange: (() -> Void)?

    private let modelFile: Configuration.Cleanup.ModelFile
    private let setup: Configuration.Setup

    /// Throttles the download callback down to what a progress bar needs.
    /// Reset at the start of each attempt.
    private var gate = ProgressGate()

    init(modelFile: Configuration.Cleanup.ModelFile, setup: Configuration.Setup) {
        self.modelFile = modelFile
        self.setup = setup
        if installedFile() != nil { phase = .installed }
    }

    // MARK: - Detection

    /// Where model files live: `~/Library/Application Support/zwisp/models`.
    static func modelsDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zwisp/models")
    }

    /// The on-disk model file, or `nil` when absent or the wrong size (an
    /// aborted download reads as missing, so it's re-fetched rather than
    /// handed to the server). Size is the cheap per-launch check; the SHA-256
    /// is verified once, right after download — hashing 2.5 GB on every
    /// launch would be pure waste.
    ///
    /// Also accepts the copy in Homebird's shared model store, where zchat
    /// downloads it when zwisp isn't installed: using the same file means the
    /// two apps share one copy of the weights in RAM (see `ModelFile.searchDirectories`).
    func installedFile() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return modelFile.searchDirectories(applicationSupport: appSupport).lazy
            .map { $0.appendingPathComponent(self.modelFile.fileName) }
            .first { url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.int64Value == self.modelFile.byteSize
            }
    }

    /// Re-derives `phase` from the disk (e.g. the user deleted the file).
    /// NO-OP while a download runs, and a `.failed` keeps its message until
    /// the user retries.
    func refreshFromDisk() {
        guard !phase.isBusy else { return }
        let onDisk = installedFile() != nil
        switch phase {
        case .installed where !onDisk: setPhase(.missing)
        case .missing where onDisk: setPhase(.installed)
        default: break
        }
    }

    // MARK: - Download

    /// Downloads the model with visible progress, verifies it, then calls
    /// `onReady(file)` on the main actor. Refuses up front if the home volume
    /// is below the configured free-space floor. Guards against a double-start.
    func startDownload(onReady: @escaping @MainActor (URL) -> Void) {
        guard !phase.isBusy else { return }
        if let existing = installedFile() {
            setPhase(.installed)
            onReady(existing)
            return
        }
        if let shortfall = diskShortfallMessage() {
            setPhase(.failed(shortfall))
            return
        }

        gate = ProgressGate()
        setPhase(.installing(stage: "Downloading cleanup model", fraction: 0))
        Log.write("cleanup model: starting download of \(modelFile.fileName)")

        Task {
            do {
                // The async download API never calls a task delegate's
                // didWriteData, so progress is read by polling the task's
                // byte count (the delegate hands the task over when it's made).
                let delegate = DownloadProgressDelegate()
                let expectedSize = modelFile.byteSize
                let poll = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        if let self, let task = delegate.task, task.countOfBytesReceived > 0 {
                            let total = task.countOfBytesExpectedToReceive > 0
                                ? task.countOfBytesExpectedToReceive : expectedSize
                            let fraction = Double(task.countOfBytesReceived) / Double(total)
                            if self.gate.shouldEmit(fraction) {
                                self.setPhase(.installing(stage: "Downloading cleanup model", fraction: fraction))
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { poll.cancel() }
                let request = URLRequest(url: modelFile.downloadURL)
                let (tempURL, response) = try await URLSession.shared.download(
                    for: request, delegate: delegate)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw InstallError(message: "Couldn't download the model (HTTP \(code))")
                }
                // The async download deletes its temp file the instant this call
                // returns, so claim it immediately.
                let staging = Self.modelsDirectory()
                    .appendingPathComponent(modelFile.fileName + ".download")
                try FileManager.default.createDirectory(
                    at: Self.modelsDirectory(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: tempURL, to: staging)

                setPhase(.installing(stage: "Verifying", fraction: nil))
                guard try await Self.verify(file: staging, sha256: modelFile.sha256,
                                            byteSize: modelFile.byteSize) else {
                    try? FileManager.default.removeItem(at: staging)
                    throw InstallError(message: "The downloaded model failed verification — retry")
                }

                let destination = Self.modelsDirectory()
                    .appendingPathComponent(modelFile.fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
                Log.write("cleanup model: installed at \(destination.path)")
                setPhase(.installed)
                onReady(destination)
            } catch let error as InstallError {
                Log.write("cleanup model: download failed — \(error.message)")
                setPhase(.failed(error.message))
            } catch {
                Log.write("cleanup model: download failed — \(error.localizedDescription)")
                setPhase(.failed("Couldn't download the model — check your connection and retry"))
            }
        }
    }

    // MARK: - Verification

    /// Streams the file through SHA-256 in chunks (never the whole 2.5 GB in
    /// memory) and checks the exact byte count. `nonisolated` so the hashing
    /// runs off the main actor.
    nonisolated private static func verify(file: URL, sha256: String,
                                           byteSize: Int64) async throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == byteSize else { return false }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            await Task.yield()   // stay preemptible during ~600 chunks
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased()
    }

    // MARK: - Helpers

    private func setPhase(_ new: InstallPhase) {
        phase = new
        onPhaseChange?()
    }

    /// A human-readable message when the home volume has less than the required
    /// free space, else `nil`. A probe failure is treated as "enough" — don't
    /// block the download on an unreadable volume.
    private func diskShortfallMessage() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        guard available < setup.minFreeBytesForCleanupModel else { return nil }
        let needGB = Double(setup.minFreeBytesForCleanupModel) / 1_073_741_824
        return String(format: "Not enough free disk space — about %.0f GB needed.", needGB)
    }

    private struct InstallError: Error {
        let message: String
    }
}

/// Hands over the download's task as soon as URLSession creates it, so its
/// byte count can be polled for progress: `download(for:delegate:)` never
/// delivers `didWriteData` to a task delegate (verified: zero calls).
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var created: URLSessionTask?

    var task: URLSessionTask? { lock.withLock { created } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { created = task }
    }
}
