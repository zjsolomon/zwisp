import Foundation
import WhisperKit
import ZwispCore

/// Owns the *download* of the WhisperKit speech model (the piece WhisperKit's
/// own init used to do invisibly). Split out so the download reports visible
/// progress into the setup window and so `Transcriber` can be handed a ready
/// folder instead of triggering a silent fetch on first use.
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

    /// Fired after every `phase` change so the setup window can re-render.
    var onPhaseChange: (() -> Void)?

    private let variant: String
    private let setup: Configuration.Setup

    /// Throttles WhisperKit's high-frequency download callback down to what a
    /// progress bar needs. Reset at the start of each download attempt.
    private var gate = ProgressGate()

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
            setPhase(.failed(shortfall))
            return
        }

        gate = ProgressGate()
        setPhase(.installing(stage: "Downloading speech model", fraction: 0))
        Log.write("speech model: starting download of \(variant)")

        Task {
            do {
                let folder = try await WhisperKit.download(
                    variant: variant,
                    progressCallback: { [weak self] progress in
                        // Fires off-main and far faster than the UI needs;
                        // throttle, then hop to the main actor to touch `phase`.
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            guard let self else { return }
                            guard self.gate.shouldEmit(fraction) else { return }
                            self.setPhase(.installing(
                                stage: "Downloading speech model", fraction: fraction))
                        }
                    })
                Log.write("speech model: download complete at \(folder.path)")
                onReady(folder)
            } catch {
                Log.write("speech model: download failed — \(error.localizedDescription)")
                setPhase(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Phase transitions driven by the caller (AppDelegate)

    /// The download finished and `Transcriber` is now compiling/loading the
    /// model (CoreML specialization). Indeterminate — no byte total to show.
    func markLoading() {
        setPhase(.installing(stage: "Compiling & loading", fraction: nil))
    }

    /// The model loaded and dictation is ready.
    func markInstalled() {
        setPhase(.installed)
    }

    /// Loading failed; surface the reason in the setup window.
    func markFailed(_ message: String) {
        setPhase(.failed(message))
    }

    // MARK: - Helpers

    private func setPhase(_ new: InstallPhase) {
        phase = new
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
