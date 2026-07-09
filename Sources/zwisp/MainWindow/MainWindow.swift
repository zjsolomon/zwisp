import AppKit
import SwiftUI
import ZwispCore

/// The unified main window: one dark-branded surface holding what used to be
/// the separate setup and settings windows, behind sidebar navigation
/// (`MainSection`). Follows the accessory-app window lifecycle the old windows
/// established: lazy single build, `isReleasedWhenClosed = false`, activate +
/// `makeKeyAndOrderFront` on show. Two liveness mechanisms carry over:
///   1. a 1 s poll `Timer` in `.common` mode while the window is open (menus
///      suspend default-mode timers) — drives the permission checklist, the
///      Home status cards, and the sidebar's setup-attention badge alike;
///   2. a `didBecomeKey` refresh, so edits made while focus was elsewhere
///      (a hotkey capture, the menu bar) show up on return.
///
/// The app layer drives everything through the frozen `Actions` struct — the
/// union of the old `SetupWindow.Actions` and `SettingsWindow.Actions` (minus
/// `openSetupGuide`, which became in-window navigation). The window and its
/// models never request permissions, kick off downloads, re-arm the hotkey
/// monitor, or touch the login item themselves.
@MainActor
final class MainWindow {
    /// Side-effecting callbacks the app layer supplies. The window/models own
    /// the reads, the store mutations, and the intent dispatch; these own
    /// everything downstream (system prompts + Settings deep links, download
    /// kick-offs, hotkey monitor re-arm, cleanup re-warms, login item).
    struct Actions {
        /// Request-then-deep-link dispatch for one permission row.
        let permissionTapped: (OnboardingPermission) -> Void
        /// Fired on the false→true edge of "all permissions granted".
        let permissionsGranted: () -> Void
        let retrySpeechDownload: () -> Void
        /// Runs the install-what's-missing cleanup chain (Ollama app + model).
        let runCleanupSetup: () -> Void
        /// The "Start Ollama…" shortcut: model already pulled, just start the
        /// server.
        let startOllamaOnly: () -> Void
        let addHotkey: () -> Void
        let removeHotkey: (Hotkey) -> Void
        let cleanupSettingChanged: () -> Void
        let dictionaryChanged: () -> Void
        let stylesChanged: () -> Void
        /// Toggles the login item and returns the NEW state after toggling.
        let toggleLaunchAtLogin: () -> Bool
    }

    private let model: MainWindowModel
    private var window: NSWindow?
    private var refreshTimer: Timer?
    /// Incrementing poll counter passed to `SetupModel.refreshLive(tick:)`.
    private var tick = 0
    private var keyObserver: NSObjectProtocol?

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         dictionaryStore: DictionaryStore, styleRuleStore: StyleRuleStore,
         speechInstaller: SpeechModelInstaller, ollamaInstaller: OllamaInstaller,
         cleanup: CleanupService, overlayStore: OverlayStore,
         statsStore: StatsStore, waveFeed: WaveFeed,
         levelProvider: @escaping () -> Float,
         config: Configuration, actions: Actions) {
        self.model = MainWindowModel(
            probe: probe, hotkeyStore: hotkeyStore,
            dictionaryStore: dictionaryStore, styleRuleStore: styleRuleStore,
            speechInstaller: speechInstaller, ollamaInstaller: ollamaInstaller,
            cleanup: cleanup, overlayStore: overlayStore,
            statsStore: statsStore, waveFeed: waveFeed,
            levelProvider: levelProvider, config: config, actions: actions)
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    /// Brings the window to the front on whatever section it was last showing,
    /// building it on first use.
    func present() {
        if window == nil {
            window = build()
            window?.center()
        }
        model.refresh()
        startRefreshTimer()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Presents the window opened to a specific section (the launch auto-show
    /// lands on Setup; the denied-mic rescue does too).
    func present(section: MainSection) {
        model.select(section)
        present()
    }

    /// Re-syncs all models. Safe to call before the window exists — the app
    /// calls it from anywhere (installer `onPhaseChange`, hotkey capture).
    func refresh() {
        model.refresh()
    }

    /// Cheap post-dictation nudge: re-snapshots the Home stats only when the
    /// window is actually on screen; a closed window costs nothing.
    func refreshHomeIfVisible() {
        guard window?.isVisible == true else { return }
        model.home.refresh()
    }

    // MARK: - Live refresh

    /// A 1 s cadence of cheap non-prompting checks, running whichever section is
    /// visible: every section shows some live status (permission rows, Home
    /// cards, the sidebar badge). `.common` mode so it keeps ticking during menu
    /// tracking. Stopped when the window closes (via `closeDelegate`).
    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main below, so the body always runs on the
            // main actor — assert it so touching the main-actor `tick`/`model`
            // from this @Sendable closure is sound.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                self.model.refreshLive(tick: self.tick)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Construction

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "zwisp"
        // The brand is dark; the window commits to it regardless of the system
        // appearance. Sheets and popovers inherit from the window.
        window.appearance = NSAppearance(named: .darkAqua)
        // Content draws edge to edge under a transparent title bar; the sidebar
        // leaves room for the traffic lights (`MainView`).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 6 / 255, green: 6 / 255,
                                         blue: 8 / 255, alpha: 1)
        window.isReleasedWhenClosed = false   // kept alive for reopening
        window.delegate = closeDelegate

        let hosting = NSHostingController(rootView: MainView(model: model))
        window.contentViewController = hosting
        // NSHostingController doesn't always adopt the SwiftUI min frame on its
        // own (a known sizing papercut), so pin a sensible min + initial size.
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.setContentSize(NSSize(width: 900, height: 620))

        // Refresh when the window regains key focus, so edits made from the
        // menu bar (or a hotkey capture that stole focus) show up on return.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (queue: .main), so hop is safe.
            MainActor.assumeIsolated { self?.refresh() }
        }

        return window
    }

    // Closing via the red button must also stop the 1 s poll. Held strongly —
    // `NSWindow.delegate` is weak.
    private lazy var closeDelegate = WindowCloseDelegate { [weak self] in self?.stopRefreshTimer() }
}
