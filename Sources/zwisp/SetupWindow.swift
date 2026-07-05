import AppKit
import SwiftUI
import ZwispCore

/// First-run setup window: a SwiftUI `SetupView` hosted inside an AppKit
/// `NSWindow` that follows the accessory-app lifecycle (lazy single build,
/// `isReleasedWhenClosed = false`, `.floating` level, activate +
/// `makeKeyAndOrderFront` on first show). Replaces the old AppKit
/// `OnboardingWindow`, preserving its three invariants:
///   1. a 1 s poll `Timer` added to `RunLoop.main` in `.common` mode (menus
///      suspend default-mode timers, which would freeze the checklist);
///   2. the rising-edge `permissionsGranted` callback (detected in `SetupModel`);
///   3. the per-permission request-then-deep-link button dispatch (owned by the
///      app layer via `Actions.permissionTapped`).
///
/// The app layer drives everything through the frozen `Actions` struct: the
/// window and its model never request permissions, kick off downloads, or re-arm
/// the hotkey monitor themselves — they call these closures and re-snapshot.
@MainActor
final class SetupWindow {
    /// Side-effecting callbacks the app layer supplies. The window/model own the
    /// reads and the intent dispatch; these own everything downstream (system
    /// permission prompts + Settings deep links, download kick-offs, hotkey
    /// monitor re-arm).
    struct Actions {
        /// Request-then-deep-link dispatch for one permission row (copied
        /// verbatim from `OnboardingWindow.rowButtonClicked` in the app layer).
        let permissionTapped: (OnboardingPermission) -> Void
        /// Fired on the false→true edge of "all permissions granted".
        let permissionsGranted: () -> Void
        let retrySpeechDownload: () -> Void
        /// Runs the install-what's-missing cleanup chain (Ollama app + model).
        let runCleanupSetup: () -> Void
        /// The "Start Ollama…" shortcut: model already pulled, just start the
        /// server.
        let startOllamaOnly: () -> Void
    }

    private let model: SetupModel
    private var window: NSWindow?
    private var refreshTimer: Timer?
    /// Incrementing poll counter passed to `model.refreshLive(tick:)`.
    private var tick = 0

    init(probe: PermissionProbe, hotkeyStore: HotkeyStore,
         speechInstaller: SpeechModelInstaller, ollamaInstaller: OllamaInstaller,
         cleanup: CleanupService, config: Configuration, actions: Actions) {
        self.model = SetupModel(
            probe: probe, hotkeyStore: hotkeyStore,
            speechInstaller: speechInstaller, ollamaInstaller: ollamaInstaller,
            cleanup: cleanup, config: config, actions: actions)
    }

    /// Brings the window to the front, building it on first use. Mirrors
    /// `OnboardingWindow.present()` so the accessory-app activation is identical.
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

    /// Re-syncs the model from the probe/installers. Safe to call before the
    /// window exists — it just refreshes the model, so the app can call it from
    /// anywhere (e.g. from an installer's `onPhaseChange`).
    func refresh() {
        model.refresh()
    }

    /// Closes the window and stops the poll. Kept private-facing; the SwiftUI
    /// footer's "Done" button and the red close button both route here (the
    /// latter via `closeDelegate`).
    private func dismiss() {
        stopRefreshTimer()
        window?.close()   // isReleasedWhenClosed = false; kept for reopening
    }

    // MARK: - Live refresh

    /// A 1 s cadence of cheap non-prompting checks. `.common` mode so the
    /// checklist keeps updating during menu tracking — the default mode suspends
    /// timers while a menu is open (preserved invariant).
    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main below, so the body always runs on the
            // main actor — assert it so touching the main-actor `tick`/`model`
            // from this @Sendable closure is sound (silences the isolation
            // warning without hopping through another Task hop).
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up zwisp"
        window.level = .floating
        window.isReleasedWhenClosed = false   // kept alive for reopening
        window.delegate = closeDelegate

        let hosting = NSHostingController(
            rootView: SetupView(model: model, dismiss: { [weak self] in self?.dismiss() }))
        window.contentViewController = hosting
        // NSHostingController doesn't always adopt the SwiftUI min frame on its
        // own (a known sizing papercut), so pin a sensible min + initial size.
        window.contentMinSize = NSSize(width: 520, height: 640)
        window.setContentSize(NSSize(width: 520, height: 640))

        return window
    }

    // Closing via the red button must also stop the 1 s poll. Held strongly —
    // `NSWindow.delegate` is weak.
    private lazy var closeDelegate = WindowCloseDelegate { [weak self] in self?.stopRefreshTimer() }
}
