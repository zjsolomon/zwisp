import AppKit
import Observation
import ServiceManagement
import ZwispCore

/// View model backing `SettingsView`. Holds the injected stores/cleanup/config
/// plus the `MainWindow.Actions` closures, and exposes plain snapshot
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
    private let overlayStore: OverlayStore
    private let editLearningStore: EditLearningStore
    let config: Configuration
    private let actions: MainWindow.Actions

    // MARK: - Snapshots (re-read on `refresh()`)

    private(set) var hotkeys: [Hotkey] = []
    private(set) var dictionaryEntries: [String] = []
    /// Mishearings per dictionary word, keyed by the stored word form.
    private(set) var dictionaryAliases: [String: [String]] = [:]
    private(set) var rules: [AppStyleRule] = []
    private(set) var defaultStyle: WritingStyle = .standard
    private(set) var perAppStylesEnabled: Bool = true
    private(set) var cleanupEnabled: Bool = false
    /// The one bundled cleanup model's display name (static — no picker).
    private(set) var cleanupModelName: String = ""
    /// Human name of the speech model, e.g. "Whisper large-v3 turbo" (the raw
    /// variant is a repo path — publisher prefix, datestamp — not a name).
    private(set) var speechModelName: String = ""
    private(set) var launchAtLogin: Bool = false
    private(set) var overlayEnabled: Bool = false
    private(set) var editLearningEnabled: Bool = false

    // MARK: - Async-loaded

    /// Human-readable cleanup status line, e.g. "Active — Qwen3 4B".
    private(set) var cleanupStatusLine: String = ""

    init(hotkeyStore: HotkeyStore, dictionaryStore: DictionaryStore,
         styleRuleStore: StyleRuleStore, cleanup: CleanupService,
         overlayStore: OverlayStore, editLearningStore: EditLearningStore,
         config: Configuration,
         actions: MainWindow.Actions) {
        self.hotkeyStore = hotkeyStore
        self.dictionaryStore = dictionaryStore
        self.styleRuleStore = styleRuleStore
        self.cleanup = cleanup
        self.overlayStore = overlayStore
        self.editLearningStore = editLearningStore
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
        dictionaryAliases = Dictionary(uniqueKeysWithValues: dictionaryEntries.map {
            ($0, dictionaryStore.aliases(for: $0))
        })
        rules = styleRuleStore.rules
        defaultStyle = styleRuleStore.defaultStyle
        perAppStylesEnabled = styleRuleStore.perAppEnabled
        cleanupEnabled = cleanup.enabled
        cleanupModelName = cleanup.modelName
        speechModelName = SpeechModelLayout.displayName(variant: config.whisperModel)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        overlayEnabled = overlayStore.enabled
        editLearningEnabled = editLearningStore.enabled
    }

    private func reloadCleanupStatus() {
        Task { @MainActor in
            let status = await cleanup.status()
            self.cleanupStatusLine = Self.describe(status)
        }
    }

    private static func describe(_ status: CleanupStatus) -> String {
        switch status {
        case .active(let model): return "Active — \(model)"
        case .unavailable: return "Cleanup engine isn't running"
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

    /// Store-only toggle: the watcher consults the store at each dictation,
    /// so flipping it needs no app-side action closure.
    func setEditLearningEnabled(_ enabled: Bool) {
        editLearningStore.enabled = enabled
        snapshot()
    }

    /// Adds a mishearing to a word; same shape as `addDictionaryWord` — only
    /// a stored change fires the app's re-warm (the alias lands in the cleanup
    /// system prompt, so the KV cache must be re-prefilled).
    @discardableResult
    func addDictionaryAlias(_ alias: String, for word: String) -> DictionaryStore.AliasAddResult {
        let result = dictionaryStore.addAlias(alias, for: word)
        switch result {
        case .added, .updated:
            actions.dictionaryChanged()
        case .duplicate, .conflict, .rejected:
            break
        }
        snapshot()
        return result
    }

    func removeDictionaryAlias(_ alias: String, for word: String) {
        dictionaryStore.removeAlias(alias, for: word)
        actions.dictionaryChanged()
        snapshot()
    }

    /// Copy for the `.rejected` inline error, mirroring the menu-bar alert.
    var dictionaryRejectionMessage: String {
        "Entries are limited to \(config.dictionary.maxEntryWords) words and "
            + "\(config.dictionary.maxEntryLength) characters."
    }

    /// Copy for the alias `.conflict` inline error.
    var aliasConflictMessage: String {
        "That already spells a dictionary word or another word's mishearing."
    }

    // MARK: - Writing styles

    func setDefaultStyle(_ style: WritingStyle) {
        styleRuleStore.defaultStyle = style
        actions.stylesChanged()
        snapshot()
    }

    func setPerAppStylesEnabled(_ enabled: Bool) {
        styleRuleStore.perAppEnabled = enabled
        actions.stylesChanged()
        snapshot()
    }

    /// Re-adds any built-in rule the user removed (their other rules and edits
    /// are untouched). Returns how many came back, for the confirmation line.
    @discardableResult
    func restoreBuiltInRules() -> Int {
        let added = styleRuleStore.addMissingBuiltInRules()
        if added > 0 { actions.stylesChanged() }
        snapshot()
        return added
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

    // MARK: - Dictation wave

    /// Persists the overlay preference. No `Actions` closure: there's no
    /// downstream side effect — the next dictation simply reads the store.
    func setOverlayEnabled(_ enabled: Bool) {
        overlayStore.enabled = enabled
        snapshot()
    }

    // MARK: - App pickers (for rule creation)

    /// Currently-running regular (Dock-visible) apps, deduped by bundle ID and
    /// sorted by name — the quick-pick source for a new rule.
    /// Pickable rule targets: "Any web browser" first, then the running apps.
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
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [(name: AppStyleRule.anyBrowserName, bundleID: AppStyleRule.anyBrowserBundleID)] + result
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
