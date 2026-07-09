import Observation
import ZwispCore

/// View model backing `SetupView`. Holds the injected probe/stores/installers
/// plus the `MainWindow.Actions` closures, and exposes plain snapshot
/// properties the SwiftUI views read. Mirrors `SettingsModel`: the model reads
/// state and forwards intents to the `Actions` closures (the app layer owns the
/// side effects — permission requests, download kick-offs, hotkey-monitor
/// re-arm) then re-snapshots.
///
/// `@Observable` so SwiftUI re-renders when a snapshot changes; `@MainActor`
/// because it reads the `@MainActor` installers and the main-thread stores.
@MainActor
@Observable
final class SetupModel {
    private let probe: PermissionProbe
    private let hotkeyStore: HotkeyStore
    private let speechInstaller: SpeechModelInstaller
    private let ollamaInstaller: OllamaInstaller
    private let cleanup: CleanupService
    let config: Configuration
    private let actions: MainWindow.Actions

    // MARK: - Snapshots (re-read on `refresh()`)

    private(set) var permissions: OnboardingState
    private(set) var speechPhase: InstallPhase
    private(set) var ollamaPhase: InstallPhase
    private(set) var cleanupModelPhase: InstallPhase
    private(set) var cleanupModelName: String
    private(set) var readyMessage: String
    /// Ollama exists on disk in some form (app bundle or Homebrew CLI). Picks
    /// the repair action when the server is down: start it vs install it.
    private(set) var ollamaOnDisk: Bool

    /// Rising-edge tracker for `permissions.allGranted`. Seeded with the initial
    /// state so the very first refresh only fires `permissionsGranted` on a true
    /// false→true transition, not on a launch where everything was already
    /// granted (that path arms the hotkey monitor separately).
    private var wasAllGranted: Bool

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         speechInstaller: SpeechModelInstaller, ollamaInstaller: OllamaInstaller,
         cleanup: CleanupService, config: Configuration, actions: MainWindow.Actions) {
        self.probe = probe
        self.hotkeyStore = hotkeyStore
        self.speechInstaller = speechInstaller
        self.ollamaInstaller = ollamaInstaller
        self.cleanup = cleanup
        self.config = config
        self.actions = actions

        // Initial snapshot (no rising-edge fire — see `wasAllGranted`).
        // `permissions` is read back for `wasAllGranted`, so compute it into a
        // local first: reading `self.permissions` before every stored property
        // (incl. `wasAllGranted`) is initialized is a compile error.
        let initialPermissions = probe.state()
        self.permissions = initialPermissions
        self.speechPhase = speechInstaller.phase
        self.ollamaPhase = ollamaInstaller.appPhase
        self.cleanupModelPhase = ollamaInstaller.modelPhase
        self.cleanupModelName = cleanup.model
        self.readyMessage = OnboardingState.readyMessage(
            hotkeyNames: hotkeyStore.hotkeys.map(\.name))
        self.ollamaOnDisk = ollamaInstaller.serverToolOnDisk()
        self.wasAllGranted = initialPermissions.allGranted
    }

    // MARK: - Derived

    /// Title for the single cleanup-section chain button, or `nil` when there's
    /// nothing to do / work is underway. Composed from the snapshots via the
    /// tested core rule so the copy lives in one place.
    var cleanupActionTitle: String? {
        SetupState(permissions: permissions,
                   speechModel: speechPhase,
                   ollamaApp: ollamaPhase,
                   cleanupModel: cleanupModelPhase)
            .cleanupActionTitle(modelName: cleanupModelName, ollamaOnDisk: ollamaOnDisk)
    }

    /// True when the chain button is the "Start Ollama…" variant — Ollama is
    /// already on disk (or its model already pulled) but the server is down, so
    /// the tap should only start the server, not re-run the install chain.
    /// Must mirror the "Start Ollama…" branch of `cleanupActionTitle`.
    var cleanupActionIsStartOnly: Bool {
        !ollamaPhase.isInstalled && (ollamaOnDisk || cleanupModelPhase.isInstalled)
    }

    // MARK: - Refresh

    /// Full re-snapshot: permissions, all three install phases, model name and
    /// ready message. Safe to call at any time (e.g. from `MainWindow.refresh()`
    /// via an installer's `onPhaseChange`).
    func refresh() {
        permissions = probe.state()
        speechPhase = speechInstaller.phase
        ollamaPhase = ollamaInstaller.appPhase
        cleanupModelPhase = ollamaInstaller.modelPhase
        cleanupModelName = cleanup.model
        readyMessage = OnboardingState.readyMessage(
            hotkeyNames: hotkeyStore.hotkeys.map(\.name))
        ollamaOnDisk = ollamaInstaller.serverToolOnDisk()
        detectRisingEdge()
    }

    /// One poll-timer tick. Permissions are cheap non-prompting reads so they
    /// refresh every tick (this is what flips a row to ✓ moments after the user
    /// grants in System Settings). Ollama/cleanup detection hits the network, so
    /// it's throttled to every third tick and skipped while a chain is running
    /// (the installers drive their own progress via `onPhaseChange`).
    func refreshLive(tick: Int) {
        refreshPermissions()
        guard tick % 3 == 0, !speechPhase.isBusy, !ollamaPhase.isBusy,
              !cleanupModelPhase.isBusy else { return }
        Task { @MainActor in
            await ollamaInstaller.refreshDetection()
            refresh()
        }
    }

    private func refreshPermissions() {
        permissions = probe.state()
        readyMessage = OnboardingState.readyMessage(
            hotkeyNames: hotkeyStore.hotkeys.map(\.name))
        detectRisingEdge()
    }

    /// Fire `permissionsGranted` on the false→true edge so the app can re-arm the
    /// hotkey tap immediately — preserved invariant from the old onboarding.
    private func detectRisingEdge() {
        let now = permissions.allGranted
        if now && !wasAllGranted {
            actions.permissionsGranted()
        }
        wasAllGranted = now
    }

    // MARK: - Intents (forward to actions, then re-snapshot)

    func tapPermission(_ permission: OnboardingPermission) {
        actions.permissionTapped(permission)
        refresh()
    }

    func retrySpeechDownload() {
        actions.retrySpeechDownload()
        refresh()
    }

    /// The main cleanup-section chain button. Routes the "Start Ollama…" variant
    /// to `startOllamaOnly` (server-only launch); everything else runs the full
    /// install-what's-missing chain.
    func runCleanupAction() {
        if cleanupActionIsStartOnly {
            actions.startOllamaOnly()
        } else {
            actions.runCleanupSetup()
        }
        refresh()
    }

    /// "Retry" on a failed Ollama-app or cleanup-model row — always re-runs the
    /// install chain (never the start-only shortcut).
    func retryCleanupSetup() {
        actions.runCleanupSetup()
        refresh()
    }
}
