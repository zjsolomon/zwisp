import AppKit
import SwiftUI
import ZwispCore

/// The Settings window: a SwiftUI `SettingsView` hosted inside an AppKit
/// `NSWindow` that follows the same accessory-app lifecycle as `SetupWindow`
/// (lazy single build, `isReleasedWhenClosed = false`, activate +
/// `makeKeyAndOrderFront` on first show). The controller stays AppKit so the
/// activation dance an `.accessory` app needs to pull a window to the front is
/// identical to the setup window's.
///
/// The app layer drives everything through the frozen `Actions` struct: the
/// window and its model never mutate the monitor, re-warm cleanup, or touch the
/// login item themselves — they call these closures and re-snapshot.
@MainActor
final class SettingsWindow {
    /// Side-effecting callbacks the app layer supplies. The window/model own the
    /// store reads and the *store* mutations; these own everything downstream
    /// (hotkey monitor re-arm, cleanup re-warm, style pre-warm, login item).
    struct Actions {
        let addHotkey: () -> Void
        let removeHotkey: (Hotkey) -> Void
        let cleanupSettingChanged: () -> Void
        let dictionaryChanged: () -> Void
        let stylesChanged: () -> Void
        /// Toggles the login item and returns the NEW state after toggling.
        let toggleLaunchAtLogin: () -> Bool
        let openSetupGuide: () -> Void
    }

    private let model: SettingsModel
    private var window: NSWindow?
    private var keyObserver: NSObjectProtocol?

    init(hotkeyStore: HotkeyStore, dictionaryStore: DictionaryStore,
         styleRuleStore: StyleRuleStore, cleanup: CleanupService,
         overlayStore: OverlayStore, config: Configuration, actions: Actions) {
        self.model = SettingsModel(
            hotkeyStore: hotkeyStore, dictionaryStore: dictionaryStore,
            styleRuleStore: styleRuleStore, cleanup: cleanup,
            overlayStore: overlayStore, config: config, actions: actions)
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    /// Brings the window to the front, building it on first use. Mirrors
    /// `SetupWindow.present()` so the accessory-app activation is identical.
    func present() {
        if window == nil {
            window = build()
            window?.center()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-syncs the model from the stores (and re-loads async cleanup status).
    /// Safe to call before the window exists — it just refreshes the model, so
    /// the app can call it from anywhere (e.g. after a hotkey capture completes).
    func refresh() {
        model.refresh()
    }

    // MARK: - Construction

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "zwisp Settings"
        window.isReleasedWhenClosed = false   // kept alive for reopening

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        window.contentViewController = hosting
        // NSHostingController doesn't always adopt the SwiftUI min frame on its
        // own (a known sizing papercut), so pin a sensible min + initial size.
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.setContentSize(NSSize(width: 560, height: 420))

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
}
