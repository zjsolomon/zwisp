import Foundation

/// The lifecycle of one installable dependency (the speech model, the Ollama
/// app, the cleanup model) as the setup window sees it. Kept in core so the
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

    /// Status copy for a dependency that is a *service* rather than an
    /// artifact — the Ollama server. Its truth is reachability, not presence
    /// on disk (a Homebrew CLI install has no app bundle at all), so the
    /// resting states read "Running"/"Not running" instead of the install
    /// wording. Progress and failure states pass through unchanged.
    public var serverStatusLine: String {
        switch self {
        case .missing: return "Not running"
        case .installed: return "Running"
        case .installing, .failed: return statusLine
        }
    }
}

/// The whole first-run picture: the three permissions plus the three
/// installable dependencies. Composes the already-tested `OnboardingState`
/// rather than duplicating it, and answers the two questions the app asks —
/// "must we auto-show setup?" and "is cleanup fully wired up?" — as tested pure
/// functions.
public struct SetupState: Equatable {
    public var permissions: OnboardingState
    public var speechModel: InstallPhase
    /// Ollama's local server is reachable — however it was installed (app
    /// bundle, Homebrew CLI, …). A reachable server IS an installed Ollama.
    public var ollamaApp: InstallPhase
    /// The recommended cleanup model appears in Ollama's `/api/tags`.
    public var cleanupModel: InstallPhase

    public init(permissions: OnboardingState,
                speechModel: InstallPhase,
                ollamaApp: InstallPhase,
                cleanupModel: InstallPhase) {
        self.permissions = permissions
        self.speechModel = speechModel
        self.ollamaApp = ollamaApp
        self.cleanupModel = cleanupModel
    }

    /// Auto-show the setup window? Only the hotkey permissions and the speech
    /// model can leave the app unable to do its core job. Cleanup is
    /// optional-by-design — a missing Ollama or cleanup model NEVER forces
    /// setup, so we don't nag about a multi-gigabyte optional download.
    public var needsSetup: Bool {
        permissions.needsSetup || !speechModel.isInstalled
    }

    /// Cleanup will actually run only when both its pieces are in place.
    public var cleanupReady: Bool {
        ollamaApp.isInstalled && cleanupModel.isInstalled
    }

    /// Title for the single cleanup-section chain button, or `nil` when there's
    /// nothing to do (already ready) or work is already underway (a phase is
    /// busy — the button would race the running chain). The title names the
    /// shortest path from here:
    /// - server up, model missing → just pull the model
    /// - server down but Ollama is on disk (app bundle or CLI) → just start it
    ///   (never offer to install alongside an existing copy; once it's up,
    ///   detection reveals whether the model still needs pulling)
    /// - nothing anywhere → install Ollama, then pull the model
    public func cleanupActionTitle(modelName: String, ollamaOnDisk: Bool = false) -> String? {
        guard !cleanupReady else { return nil }
        guard !ollamaApp.isBusy, !cleanupModel.isBusy else { return nil }
        if ollamaApp.isInstalled {
            return "Download \(modelName) (~2.6 GB)…"
        }
        if ollamaOnDisk || cleanupModel.isInstalled {
            return "Start Ollama…"
        }
        return "Install Ollama & download \(modelName)…"
    }
}

/// Throttles the flood of progress callbacks a download fires (WhisperKit's and
/// Ollama's both call back far faster than a UI needs to repaint), while never
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
