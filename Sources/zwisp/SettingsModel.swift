import AppKit
import Observation
import ServiceManagement
import ZwispCore

/// View model backing `SettingsView`. Holds the injected stores/cleanup/config
/// plus the `SettingsWindow.Actions` closures, and exposes plain snapshot
/// properties the SwiftUI views read. Every mutation follows one shape: mutate
/// the store, call the matching `Actions` closure (the app layer owns the side
/// effects — monitor re-arm, cleanup re-warm, style pre-warm), then re-snapshot.
///
/// `@Observable` so SwiftUI re-renders when a snapshot changes; `@MainActor`
/// because it touches AppKit (`NSWorkspace`, `NSOpenPanel`) and the stores are
/// main-thread state.
@MainActor
@Observable
final class SettingsModel {
    private let hotkeyStore: HotkeyStore
    private let dictionaryStore: DictionaryStore
    private let styleRuleStore: StyleRuleStore
    private let cleanup: CleanupService
    let config: Configuration
    private let actions: SettingsWindow.Actions

    // MARK: - Snapshots (re-read on `refresh()`)

    private(set) var hotkeys: [Hotkey] = []
    private(set) var dictionaryEntries: [String] = []
    private(set) var rules: [AppStyleRule] = []
    private(set) var defaultStyle: WritingStyle = .standard
    private(set) var cleanupEnabled: Bool = false
    private(set) var cleanupModel: String = ""
    private(set) var whisperModel: String = ""
    private(set) var launchAtLogin: Bool = false

    // MARK: - Async-loaded

    /// Models Ollama reports as installed. `nil` while loading, or when Ollama
    /// is unreachable — the picker uses this to show a spinner / fall back.
    private(set) var availableModels: [String]?
    /// Human-readable cleanup status line, e.g. "Active — llama3.2".
    private(set) var cleanupStatusLine: String = ""

    init(hotkeyStore: HotkeyStore, dictionaryStore: DictionaryStore,
         styleRuleStore: StyleRuleStore, cleanup: CleanupService,
         config: Configuration, actions: SettingsWindow.Actions) {
        self.hotkeyStore = hotkeyStore
        self.dictionaryStore = dictionaryStore
        self.styleRuleStore = styleRuleStore
        self.cleanup = cleanup
        self.config = config
        self.actions = actions
        snapshot()
    }

    // MARK: - Refresh

    /// Re-reads every snapshot from the stores and kicks off the async cleanup
    /// status/model reload. Safe to call at any time — it only reads state.
    func refresh() {
        snapshot()
        reloadCleanupStatus()
    }

    private func snapshot() {
        hotkeys = hotkeyStore.hotkeys
        dictionaryEntries = dictionaryStore.sortedEntries
        rules = styleRuleStore.rules
        defaultStyle = styleRuleStore.defaultStyle
        cleanupEnabled = cleanup.enabled
        cleanupModel = cleanup.model
        whisperModel = config.whisperModel
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func reloadCleanupStatus() {
        availableModels = nil
        Task { @MainActor in
            let models = await cleanup.availableModels()
            let status = await cleanup.status()
            self.availableModels = models
            self.cleanupStatusLine = Self.describe(status)
        }
    }

    private static func describe(_ status: CleanupStatus) -> String {
        switch status {
        case .active(let model): return "Active — \(model)"
        case .unavailable: return "Ollama not reachable"
        case .off: return "Cleanup is off"
        }
    }

    // MARK: - Hotkeys

    /// Opens the existing AppKit capture panel (via the app layer). The captured
    /// key is picked up on the next `refresh()` — the window fires one when it
    /// regains key focus after capture, and the app's completion also refreshes.
    func addHotkey() {
        actions.addHotkey()
    }

    /// The app layer's closure owns the store mutation *and* the monitor re-arm,
    /// so this only delegates and re-snapshots (see plan §Phase 2C).
    func removeHotkey(_ hotkey: Hotkey) {
        actions.removeHotkey(hotkey)
        snapshot()
    }

    // MARK: - Cleanup

    func setCleanupEnabled(_ enabled: Bool) {
        cleanup.enabled = enabled
        actions.cleanupSettingChanged()
        refresh()
    }

    func setCleanupModel(_ model: String) {
        cleanup.model = model
        actions.cleanupSettingChanged()
        refresh()
    }

    // MARK: - Dictionary

    /// Adds a word and returns the raw `AddResult` so the view can show inline
    /// feedback (an error on `.rejected`, a subtle note on `.duplicate`). Only
    /// `.added`/`.updated` fire the app's re-warm.
    @discardableResult
    func addDictionaryWord(_ word: String) -> DictionaryStore.AddResult {
        let result = dictionaryStore.add(word)
        switch result {
        case .added, .updated:
            actions.dictionaryChanged()
        case .duplicate, .rejected:
            break
        }
        snapshot()
        return result
    }

    func removeDictionaryWord(_ word: String) {
        dictionaryStore.remove(word)
        actions.dictionaryChanged()
        snapshot()
    }

    /// Copy for the `.rejected` inline error, mirroring the menu-bar alert.
    var dictionaryRejectionMessage: String {
        "Entries are limited to \(config.dictionary.maxEntryWords) words and "
            + "\(config.dictionary.maxEntryLength) characters."
    }

    // MARK: - Writing styles

    func setDefaultStyle(_ style: WritingStyle) {
        styleRuleStore.defaultStyle = style
        actions.stylesChanged()
        snapshot()
    }

    /// Adds a rule. Returns `false` on a duplicate `(bundleID, titleContains)`
    /// target so the view can flag it.
    @discardableResult
    func addRule(_ rule: AppStyleRule) -> Bool {
        let added = styleRuleStore.add(rule)
        if added { actions.stylesChanged() }
        snapshot()
        return added
    }

    func updateRule(_ rule: AppStyleRule) {
        styleRuleStore.update(rule)
        actions.stylesChanged()
        snapshot()
    }

    func removeRule(id: UUID) {
        styleRuleStore.remove(id: id)
        actions.stylesChanged()
        snapshot()
    }

    // MARK: - Launch at login

    /// Toggles the login item via the app layer (which owns `SMAppService`) and
    /// stores the new state it returns.
    func toggleLaunchAtLogin() {
        launchAtLogin = actions.toggleLaunchAtLogin()
    }

    // MARK: - Setup guide

    func openSetupGuide() {
        actions.openSetupGuide()
    }

    // MARK: - App pickers (for rule creation)

    /// Currently-running regular (Dock-visible) apps, deduped by bundle ID and
    /// sorted by name — the quick-pick source for a new rule.
    func runningApps() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        var result: [(name: String, bundleID: String)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            let name = app.localizedName ?? bundleID
            result.append((name: name, bundleID: bundleID))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Presents an open panel rooted at /Applications so the user can pick an
    /// app that isn't currently running. Returns its display name + bundle ID,
    /// or `nil` if cancelled or the pick isn't a valid bundle.
    func pickAppFromDisk() -> (name: String, bundleID: String)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name: name, bundleID: bundleID)
    }
}
