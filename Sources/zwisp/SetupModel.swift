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
    private let cleanupInstaller: CleanupModelInstaller
    private let cleanup: CleanupService
    let config: Configuration
    private let actions: MainWindow.Actions

    // MARK: - Snapshots (re-read on `refresh()`)

    private(set) var permissions: OnboardingState
    private(set) var speechPhase: InstallPhase
    /// Explanatory/recovery line under the speech-model row ("first launch
    /// compiles the model — minutes are normal", "retry resumes"), or `nil`.
    private(set) var speechHint: String?
    private(set) var cleanupModelPhase: InstallPhase
    private(set) var cleanupModelName: String
    /// Human name of the speech model in use, e.g. "Whisper large-v3 turbo" —
    /// the Setup row names it the way the cleanup row names its model.
    let speechModelName: String
    private(set) var readyMessage: String

    /// Rising-edge tracker for `permissions.allGranted`. Seeded with the initial
    /// state so the very first refresh only fires `permissionsGranted` on a true
    /// false→true transition, not on a launch where everything was already
    /// granted (that path arms the hotkey monitor separately).
    private var wasAllGranted: Bool

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         speechInstaller: SpeechModelInstaller, cleanupInstaller: CleanupModelInstaller,
         cleanup: CleanupService, config: Configuration, actions: MainWindow.Actions) {
        self.probe = probe
        self.hotkeyStore = hotkeyStore
        self.speechInstaller = speechInstaller
        self.cleanupInstaller = cleanupInstaller
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
        self.speechHint = speechInstaller.phaseHint
        self.cleanupModelPhase = cleanupInstaller.phase
        self.cleanupModelName = cleanup.modelName
        self.speechModelName = SpeechModelLayout.displayName(variant: config.whisperModel)
        self.readyMessage = OnboardingState.readyMessage(
            hotkeyNames: hotkeyStore.hotkeys.map(\.name))
        self.wasAllGranted = initialPermissions.allGranted
    }

    // MARK: - Derived

    /// Title for the cleanup-section download button, or `nil` when there's
    /// nothing to do / the download is underway. Composed from the snapshots
    /// via the tested core rule so the copy lives in one place.
    var cleanupActionTitle: String? {
        SetupState(permissions: permissions,
                   speechModel: speechPhase,
                   cleanupModel: cleanupModelPhase)
            .cleanupActionTitle(modelName: cleanupModelName)
    }

    // MARK: - Refresh

    /// Full re-snapshot: permissions, both install phases, and the ready
    /// message. Safe to call at any time (e.g. from `MainWindow.refresh()`
    /// via an installer's `onPhaseChange`).
    func refresh() {
        permissions = probe.state()
        speechPhase = speechInstaller.phase
        speechHint = speechInstaller.phaseHint
        cleanupModelPhase = cleanupInstaller.phase
        cleanupModelName = cleanup.modelName
        readyMessage = OnboardingState.readyMessage(
            hotkeyNames: hotkeyStore.hotkeys.map(\.name))
        detectRisingEdge()
    }

    /// One poll-timer tick. Permissions are cheap non-prompting reads so they
    /// refresh every tick (this is what flips a row to ✓ moments after the user
    /// grants in System Settings). The cleanup model's disk check is throttled
    /// to every third tick and skipped while a download runs (the installer
    /// drives its own progress via `onPhaseChange`).
    func refreshLive(tick: Int) {
        refreshPermissions()
        guard tick % 3 == 0, !speechPhase.isBusy, !cleanupModelPhase.isBusy else { return }
        cleanupInstaller.refreshFromDisk()
        refresh()
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

    /// The cleanup-section download button — and the "Retry" on a failed row.
    func runCleanupAction() {
        actions.runCleanupSetup()
        refresh()
    }
}
