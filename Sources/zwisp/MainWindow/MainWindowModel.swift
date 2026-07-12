import Observation
import ZwispCore

/// Root view model for the unified main window: the sidebar selection plus the
/// three per-area models. `SetupModel` and `SettingsModel` are the same tested
/// seams the old two-window layout used — this class only composes them and
/// adds navigation.
@MainActor
@Observable
final class MainWindowModel {
    let setup: SetupModel
    let settings: SettingsModel
    let home: HomeModel
    let waveFeed: WaveFeed
    /// Live mic level for the Home equalizer (the recorder's lock-guarded
    /// O(1) read).
    let levelProvider: () -> Float
    let config: Configuration

    var selection: MainSection = .home

    /// The sidebar's orange badge on the Setup row — the same gate that
    /// auto-shows the window at launch (hotkey permissions missing OR the
    /// speech model absent; optional cleanup never nags).
    var setupNeedsAttention: Bool {
        MainNav.setupNeedsAttention(permissions: setup.permissions,
                                    speechModelInstalled: setup.speechPhase.isInstalled)
    }

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         dictionaryStore: DictionaryStore, styleRuleStore: StyleRuleStore,
         speechInstaller: SpeechModelInstaller, cleanupInstaller: CleanupModelInstaller,
         cleanup: CleanupService, overlayStore: OverlayStore,
         statsStore: StatsStore, waveFeed: WaveFeed,
         levelProvider: @escaping () -> Float,
         config: Configuration, actions: MainWindow.Actions) {
        self.setup = SetupModel(
            probe: probe, hotkeyStore: hotkeyStore,
            speechInstaller: speechInstaller, cleanupInstaller: cleanupInstaller,
            cleanup: cleanup, config: config, actions: actions)
        self.settings = SettingsModel(
            hotkeyStore: hotkeyStore, dictionaryStore: dictionaryStore,
            styleRuleStore: styleRuleStore, cleanup: cleanup,
            overlayStore: overlayStore, config: config, actions: actions)
        self.home = HomeModel(statsStore: statsStore, hotkeyStore: hotkeyStore)
        self.waveFeed = waveFeed
        self.levelProvider = levelProvider
        self.config = config
    }

    func select(_ section: MainSection) {
        selection = section
    }

    func refresh() {
        setup.refresh()
        settings.refresh()
        home.refresh()
    }

    /// One poll-timer tick: permissions every second, network detection
    /// throttled inside `SetupModel.refreshLive`.
    func refreshLive(tick: Int) {
        setup.refreshLive(tick: tick)
    }
}
