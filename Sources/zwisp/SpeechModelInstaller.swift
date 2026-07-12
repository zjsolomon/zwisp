import Foundation
import WhisperKit
import ZwispCore

/// Owns the *download* of the WhisperKit speech model (the piece WhisperKit's
/// own init used to do invisibly). Split out so the download reports visible
/// progress into the setup window and so `Transcriber` can be handed a ready
/// folder instead of triggering a silent fetch on first use.
///
/// The two long stages stay visibly alive: the download is watched for stalls
/// (no bytes for `stallSeconds` cancels it into a retryable failure instead of
/// hanging forever), and the load/compile stage — CoreML specialization that
/// can take minutes on a first launch — ticks an elapsed clock so it never
/// looks hung. `phaseHint` carries the explanatory/recovery line the setup row
/// shows under the status.
///
/// A `@MainActor` class because it drives UI state: `phase` is read on the main
/// thread and `onPhaseChange` repaints the setup window. WhisperKit's download
/// progress callback fires off-main, so every mutation from inside it hops back
/// to the main actor.
@MainActor
final class SpeechModelInstaller {
    /// Where this install currently stands. UI reads it; only this class writes
    /// it (always on the main actor), firing `onPhaseChange` on every change.
    private(set) var phase: InstallPhase = .missing

    /// One explanatory or recovery line for the setup row (what's happening,
    /// what to do if it broke), or `nil` when the status speaks for itself.
    private(set) var phaseHint: String?

    /// Fired after every `phase` change so the setup window can re-render.
    var onPhaseChange: (() -> Void)?

    private let variant: String
    private let setup: Configuration.Setup

    /// Throttles WhisperKit's high-frequency download callback down to what a
    /// progress bar needs. Reset at the start of each download attempt.
    private var gate = ProgressGate()

    /// The in-flight download, so the stall watchdog can cancel it.
    private var downloadTask: Task<Void, Never>?
    /// When download bytes last arrived; the watchdog compares against it.
    private var lastProgressAt = Date()
    /// Set by the watchdog just before cancelling, so the catch can tell a
    /// stall from a user-visible network error.
    private var stalledByWatchdog = false
    /// When the load/compile stage began — drives the elapsed clock.
    private var loadingStarted: Date?
    /// One-second heartbeat while a stage runs: ticks the elapsed clock and
    /// checks the download for stalls. Stopped whenever the phase settles.
    private var ticker: Timer?

    /// Cancel the download after this long without a single byte of progress.
    /// Generous — a slow connection still trickles callbacks; only a genuinely
    /// dead transfer goes quiet this long.
    static let stallSeconds: TimeInterval = 90

    static let downloadHint =
        "Safe to quit — the download resumes on relaunch, keeping finished files."
    static let loadingHint =
        "First launch only: macOS is compiling the model for the Neural Engine. "
        + "A few minutes is normal. Safe to quit — setup resumes on relaunch."
    static let retryHint =
        "Retrying picks up where it left off — finished files aren't re-downloaded."

    init(variant: String, setup: Configuration.Setup) {
        self.variant = variant
        self.setup = setup
    }

    // MARK: - Detection

    /// The on-disk model folder, or `nil` if the model is absent or only
    /// partially downloaded. Builds WhisperKit's exact storage path from the
    /// real Documents directory, lists its direct contents, and gates on
    /// `SpeechModelLayout.isComplete` — a folder missing any required `.mlmodelc`
    /// bundle (an aborted download) reads as absent so we re-fetch rather than
    /// hand `Transcriber` a folder it can't load.
    func installedFolder() -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let path = SpeechModelLayout.modelFolderPath(
            documentsPath: documents.path, variant: variant)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return nil }
        guard SpeechModelLayout.isComplete(folderContents: Set(contents)) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Download

    /// Downloads the model with visible progress, then calls `onReady(folder)`
    /// on the main actor. Refuses up front if the home volume is below the
    /// configured free-space floor (better to fail cleanly than half-download
    /// and error deep inside HubApi). Guards against a double-start: while a
    /// download is already in flight this is a no-op.
    func startDownload(onReady: @escaping @MainActor (URL) -> Void) {
        guard !phase.isBusy else { return }

        if let shortfall = diskShortfallMessage() {
            setPhase(.failed(shortfall), hint: nil)
            return
        }

        gate = ProgressGate()
        lastProgressAt = Date()
        stalledByWatchdog = false
        setPhase(.installing(stage: "Downloading speech model", fraction: 0),
                 hint: Self.downloadHint)
        startTicker()
        Log.write("speech model: starting download of \(variant)")

        downloadTask = Task {
            do {
                let folder = try await WhisperKit.download(
                    variant: variant,
                    progressCallback: { [weak self] progress in
                        // Fires off-main and far faster than the UI needs;
                        // throttle, then hop to the main actor to touch `phase`.
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            guard let self else { return }
                            self.lastProgressAt = Date()
                            guard self.gate.shouldEmit(fraction) else { return }
                            self.setPhase(.installing(
                                stage: "Downloading speech model", fraction: fraction),
                                hint: Self.downloadHint)
                        }
                    })
                Log.write("speech model: download complete at \(folder.path)")
                onReady(folder)
            } catch {
                if self.stalledByWatchdog || error is CancellationError {
                    Log.write("speech model: download stalled (no progress for \(Int(Self.stallSeconds))s); cancelled")
                    self.finishStage(.failed("Download stalled — check your connection, then retry"),
                                     hint: Self.retryHint)
                } else {
                    Log.write("speech model: download failed — \(error.localizedDescription)")
                    self.finishStage(.failed(error.localizedDescription), hint: Self.retryHint)
                }
            }
        }
    }

    // MARK: - Phase transitions driven by the caller (AppDelegate)

    /// The download finished and `Transcriber` is now compiling/loading the
    /// model (CoreML specialization). There's no fraction to show, so the
    /// ticker keeps an elapsed clock running — minutes of visible progress
    /// instead of a stage that looks hung.
    func markLoading() {
        loadingStarted = Date()
        setPhase(.installing(stage: Self.loadingStage(elapsed: 0), fraction: nil),
                 hint: Self.loadingHint)
        startTicker()
    }

    /// The model loaded and dictation is ready.
    func markInstalled() {
        finishStage(.installed, hint: nil)
    }

    /// Loading failed; surface the reason in the setup window.
    func markFailed(_ message: String) {
        finishStage(.failed(message), hint: Self.retryHint)
    }

    // MARK: - Heartbeat

    private static func loadingStage(elapsed: TimeInterval) -> String {
        "Optimizing for this Mac — \(InstallPhase.elapsedLabel(seconds: elapsed))"
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Scheduled-timer body runs on the main run loop; assert the
            // isolation so this @Sendable closure can touch main-actor state.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard case .installing(_, let fraction) = phase else { return }
        if let loadingStarted {
            // Loading: advance the elapsed clock.
            setPhase(.installing(
                stage: Self.loadingStage(elapsed: Date().timeIntervalSince(loadingStarted)),
                fraction: nil), hint: Self.loadingHint)
        } else if fraction != nil,
                  Date().timeIntervalSince(lastProgressAt) > Self.stallSeconds {
            // Downloading: a transfer this quiet is dead — cancel it into a
            // clean, retryable failure instead of spinning forever.
            stalledByWatchdog = true
            downloadTask?.cancel()
        }
    }

    /// Settles the phase and stops the heartbeat (terminal states don't tick).
    private func finishStage(_ terminal: InstallPhase, hint: String?) {
        ticker?.invalidate()
        ticker = nil
        loadingStarted = nil
        downloadTask = nil
        setPhase(terminal, hint: hint)
    }

    // MARK: - Helpers

    private func setPhase(_ new: InstallPhase, hint: String?) {
        phase = new
        phaseHint = hint
        onPhaseChange?()
    }

    /// A human-readable message when the home volume has less than the required
    /// free space, else `nil`. Uses `volumeAvailableCapacityForImportantUsage`,
    /// which reflects space the OS will actually make available (purgeable
    /// caches included) rather than the raw free bytes.
    private func diskShortfallMessage() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }  // Can't tell — don't block the download on a probe failure.
        guard available < setup.minFreeBytesForSpeechModel else { return nil }
        let needGB = Double(setup.minFreeBytesForSpeechModel) / 1_073_741_824
        return String(format: "Not enough free disk space — about %.0f GB needed.", needGB)
    }
}
