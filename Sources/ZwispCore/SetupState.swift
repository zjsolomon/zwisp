import Foundation

/// The lifecycle of one installable dependency (the speech model, the cleanup
/// model) as the setup window sees it. Kept in core so the
/// status copy and the derived flags are tested in one place, and so the app
/// layer's installers can drive a value type instead of scattering UI strings.
public enum InstallPhase: Equatable {
    case missing
    /// Work in progress. `fraction == nil` means indeterminate (no byte totals
    /// yet) so the UI shows a spinner rather than a stuck-at-0 bar.
    case installing(stage: String, fraction: Double?)
    case installed
    case failed(String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    public var isBusy: Bool {
        if case .installing = self { return true }
        return false
    }

    /// Renders elapsed seconds as "m:ss" for a long-running indeterminate
    /// stage ("Optimizing for this Mac — 1:42"). A visibly ticking clock is
    /// what separates "working" from "hung" when there's no fraction to show.
    public static func elapsedLabel(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// One-line status for the setup row. Percent is rendered only when a
    /// fraction is known, and clamped to 0–100 so a slightly-out-of-range
    /// fraction (rounding, an over-count) can't print "-3%" or "104%".
    public var statusLine: String {
        switch self {
        case .missing:
            return "Not installed"
        case .installing(let stage, let fraction):
            guard let fraction else { return "\(stage)…" }
            let clamped = min(max(fraction, 0), 1)
            let percent = Int((clamped * 100).rounded())
            return "\(stage) — \(percent)%"
        case .installed:
            return "Installed"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

}

/// The whole first-run picture: the three permissions plus the two
/// installable dependencies (the speech model and the cleanup model — the
/// cleanup *engine* ships inside the app, so there's nothing else to install).
/// Composes the already-tested `OnboardingState` rather than duplicating it,
/// and answers the two questions the app asks — "must we auto-show setup?" and
/// "is cleanup fully wired up?" — as tested pure functions.
public struct SetupState: Equatable {
    public var permissions: OnboardingState
    public var speechModel: InstallPhase
    /// The bundled cleanup model's GGUF file is on disk and intact.
    public var cleanupModel: InstallPhase

    public init(permissions: OnboardingState,
                speechModel: InstallPhase,
                cleanupModel: InstallPhase) {
        self.permissions = permissions
        self.speechModel = speechModel
        self.cleanupModel = cleanupModel
    }

    /// Auto-show the setup window? Only the hotkey permissions and the speech
    /// model can leave the app unable to do its core job. Cleanup is
    /// optional-by-design — a missing cleanup model NEVER forces setup, so we
    /// don't nag about a multi-gigabyte optional download.
    public var needsSetup: Bool {
        permissions.needsSetup || !speechModel.isInstalled
    }

    /// Cleanup will actually run once its model is on disk (the engine itself
    /// ships inside the app).
    public var cleanupReady: Bool {
        cleanupModel.isInstalled
    }

    /// Title for the cleanup-section download button, or `nil` when there's
    /// nothing to do (already ready) or the download is already underway (the
    /// button would race it).
    public func cleanupActionTitle(modelName: String) -> String? {
        guard !cleanupReady, !cleanupModel.isBusy else { return nil }
        return "Download \(modelName) (~2.5 GB)…"
    }
}

/// Throttles the flood of progress callbacks a download fires (they arrive far
/// faster than a UI needs to repaint), while never
/// dropping the two frames that matter: the 0 that starts the bar and the 1
/// that completes it. Everything in between is emitted only once it has moved
/// by at least `minDelta`.
public struct ProgressGate {
    private let minDelta: Double
    private var lastEmitted: Double?

    public init(minDelta: Double = 0.01) {
        self.minDelta = minDelta
    }

    public mutating func shouldEmit(_ fraction: Double) -> Bool {
        // Endpoints always pass: the bar must visibly start and finish.
        if fraction <= 0 || fraction >= 1 {
            lastEmitted = fraction
            return true
        }
        guard let last = lastEmitted else {
            lastEmitted = fraction
            return true
        }
        guard abs(fraction - last) >= minDelta else { return false }
        lastEmitted = fraction
        return true
    }
}
