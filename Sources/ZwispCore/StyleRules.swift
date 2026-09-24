import Foundation

/// A per-application writing-style rule: "when the frontmost app is this bundle
/// (optionally with this substring in the focused window title), clean into
/// this style". The title match lets one browser serve several styles — e.g.
/// Safari + "Gmail" → formal, Safari otherwise → the default.
public struct AppStyleRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Compared case-insensitively against `NSRunningApplication.bundleIdentifier`.
    public var bundleID: String
    /// Human-readable app name, for display only.
    public var appName: String
    /// Optional case-insensitive substring the focused window title must
    /// contain for the rule to apply. `nil` = a bare rule that matches the app
    /// regardless of title.
    public var titleContains: String?
    public var style: WritingStyle

    public init(id: UUID = UUID(), bundleID: String, appName: String,
                titleContains: String? = nil, style: WritingStyle) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.titleContains = titleContains
        self.style = style
    }

    /// The pseudo bundle ID that makes a rule apply to *every* web browser
    /// (`StyleResolver.browserBundleIDs`) — so "Gmail → Formal" is one rule,
    /// not one per browser. Not a real bundle ID, so it can never collide.
    public static let anyBrowserBundleID = "zwisp.any-browser"
    public static let anyBrowserName = "Any web browser"

    /// A rule targeting every known browser. Title-scoped by default — a bare
    /// any-browser rule would restyle all web dictation.
    public static func anyBrowser(titleContains: String, style: WritingStyle) -> AppStyleRule {
        AppStyleRule(bundleID: anyBrowserBundleID, appName: anyBrowserName,
                     titleContains: titleContains, style: style)
    }

    public var isAnyBrowser: Bool {
        bundleID.caseInsensitiveCompare(Self.anyBrowserBundleID) == .orderedSame
    }
}

/// Pure resolution of a frontmost-app snapshot to a `WritingStyle`. Split out so
/// the precedence rules are unit-testable without any AppKit/AX plumbing.
public enum StyleResolver {
    /// Bundle IDs an "any web browser" rule stands for. Compared
    /// case-insensitively. Extend freely — a browser missing here just needs
    /// its own rule.
    public static let browserBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.browser",     // Arc
        "com.brave.browser",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.kagi.kagimacos",             // Orion
        "app.zen-browser.zen",
        "org.chromium.chromium",
        "com.duckduckgo.macos.browser",
    ]

    /// For the UI: what "any web browser" means, in words.
    public static let browserNamesSummary =
        "Safari, Chrome, Edge, Firefox, Arc, Brave, Vivaldi, Opera, Orion and more"

    public static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID.lowercased())
    }

    /// Resolves the style for a frontmost app.
    ///
    /// Precedence: rules naming the app's own `bundleID` (case-insensitively)
    /// beat any-browser rules, and within each group a title rule whose
    /// substring occurs (case-insensitively) in `windowTitle` wins over a bare
    /// rule *regardless of array order*; among title rules, the first match
    /// wins. So: app title rule → any-browser title rule → app bare rule →
    /// any-browser bare rule → `defaultStyle`. A title rule never matches a
    /// `nil` window title (an AX read failure degrades gracefully to the bare
    /// rule). A `nil` `bundleID` or no matching rule falls through to
    /// `defaultStyle`.
    public static func resolve(bundleID: String?, windowTitle: String?,
                               rules: [AppStyleRule], defaultStyle: WritingStyle) -> WritingStyle {
        guard let bundleID else { return defaultStyle }
        let exact = rules.filter {
            !$0.isAnyBrowser && $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        let generic = isBrowser(bundleID) ? rules.filter(\.isAnyBrowser) : []

        // Title rules take precedence over bare rules; first match wins.
        if let windowTitle {
            for rule in exact + generic {
                if let needle = rule.titleContains, !needle.isEmpty,
                   windowTitle.range(of: needle, options: .caseInsensitive) != nil {
                    return rule.style
                }
            }
        }

        // No title rule matched — fall back to the first bare rule.
        if let bare = (exact + generic).first(where: { $0.titleContains == nil }) {
            return bare.style
        }
        return defaultStyle
    }
}

/// Per-app writing-style rules plus the fallback default, persisted in
/// `UserDefaults`. Follows `DictionaryStore`'s patterns: an injectable
/// `defaults` suite, `private(set)` state, and a `persist()` on every mutation.
public final class StyleRuleStore {
    /// Insertion order, which is also resolution order for same-app rules. Use
    /// this directly for UI.
    public private(set) var rules: [AppStyleRule]

    /// The style used when no rule matches — or always, when per-app rules
    /// are switched off. Persisted on set.
    public var defaultStyle: WritingStyle {
        didSet { defaults.set(defaultStyle.rawValue, forKey: Self.defaultStyleKey) }
    }

    /// Whether the per-app rules apply at all. Off → every dictation uses
    /// `defaultStyle` and `resolve` never consults the rules (the app layer
    /// also skips the window-title read then). Absent → on. Persisted on set.
    public var perAppEnabled: Bool {
        didSet { defaults.set(perAppEnabled, forKey: Self.perAppEnabledKey) }
    }

    private let defaults: UserDefaults
    static let rulesKey = "styleRules"
    static let defaultStyleKey = "defaultWritingStyle"
    static let perAppEnabledKey = "styleRulesEnabled"
    static let seededKey = "styleRulesSeeded"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultStyleKey),
           let style = WritingStyle(rawValue: raw) {
            self.defaultStyle = style
        } else {
            self.defaultStyle = .standard
        }
        self.perAppEnabled = (defaults.object(forKey: Self.perAppEnabledKey) as? Bool) ?? true
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([LenientRule].self, from: data) {
            // Drop only the rules with an unknown style raw value; keep the rest.
            self.rules = decoded.compactMap(\.rule)
        } else {
            self.rules = []
        }
    }

    /// Adds a rule, unless one with the same `(bundleID, titleContains)` pair
    /// (both compared case-insensitively) already exists — returns `false` then.
    @discardableResult
    public func add(_ rule: AppStyleRule) -> Bool {
        guard !rules.contains(where: { Self.sameTarget($0, rule) }) else { return false }
        rules.append(rule)
        persist()
        return true
    }

    /// Replaces the rule with the same `id`, if present.
    public func update(_ rule: AppStyleRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persist()
    }

    /// Removes the rule with `id`, if present.
    public func remove(id: UUID) {
        let before = rules.count
        rules.removeAll { $0.id == id }
        if rules.count != before { persist() }
    }

    /// Convenience over the pure `StyleResolver`, using the stored rules and
    /// default. With per-app rules off, always the default.
    public func resolve(bundleID: String?, windowTitle: String?) -> WritingStyle {
        guard perAppEnabled else { return defaultStyle }
        return StyleResolver.resolve(bundleID: bundleID, windowTitle: windowTitle,
                                     rules: rules, defaultStyle: defaultStyle)
    }

    // MARK: - Built-in rules

    /// Seeds `builtInRules` exactly once per defaults suite (a flag, not "the
    /// list is empty"), merging with whatever the user already has: an existing
    /// rule for the same target is kept as is. Removing a built-in afterwards
    /// sticks — this never runs again. Returns how many rules were added.
    @discardableResult
    public func seedBuiltInRulesIfNeeded() -> Int {
        guard !defaults.bool(forKey: Self.seededKey) else { return 0 }
        defaults.set(true, forKey: Self.seededKey)
        return addMissingBuiltInRules()
    }

    /// Adds every built-in rule whose target has no rule yet; the user's edits
    /// to existing rules are untouched. The "Restore built-in rules" action.
    /// Returns how many rules were added.
    @discardableResult
    public func addMissingBuiltInRules() -> Int {
        var added = 0
        for rule in Self.builtInRules where add(rule) { added += 1 }
        return added
    }

    /// The starting point every install gets: the common mail and chat apps,
    /// plus the same services when they are open in a browser tab — one
    /// any-browser rule each, matched on the window title. Formal for mail and
    /// documents, casual for chat; anything else stays on the default. Bundle
    /// IDs are the shipping ones as of 2026-09; each `(bundleID,
    /// titleContains)` target is unique (tested), which `add` relies on.
    public static let builtInRules: [AppStyleRule] = [
        // Mail + documents → formal.
        AppStyleRule(bundleID: "com.apple.mail", appName: "Mail", style: .formal),
        AppStyleRule(bundleID: "com.microsoft.Outlook", appName: "Microsoft Outlook", style: .formal),
        AppStyleRule(bundleID: "com.readdle.SparkDesktop", appName: "Spark", style: .formal),
        AppStyleRule(bundleID: "com.apple.iWork.Pages", appName: "Pages", style: .formal),
        AppStyleRule(bundleID: "com.microsoft.Word", appName: "Microsoft Word", style: .formal),
        // Chat → casual.
        AppStyleRule(bundleID: "com.apple.MobileSMS", appName: "Messages", style: .casual),
        AppStyleRule(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", style: .casual),
        AppStyleRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: .casual),
        AppStyleRule(bundleID: "com.hnc.Discord", appName: "Discord", style: .casual),
        AppStyleRule(bundleID: "ru.keepcoder.Telegram", appName: "Telegram", style: .casual),
        AppStyleRule(bundleID: "org.telegram.desktop", appName: "Telegram Desktop", style: .casual),
        AppStyleRule(bundleID: "org.whispersystems.signal-desktop", appName: "Signal", style: .casual),
        AppStyleRule(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams", style: .casual),
        // The same services in a browser tab, by window title.
        .anyBrowser(titleContains: "Gmail", style: .formal),
        .anyBrowser(titleContains: "Outlook", style: .formal),
        .anyBrowser(titleContains: "iCloud Mail", style: .formal),
        .anyBrowser(titleContains: "Proton Mail", style: .formal),
        .anyBrowser(titleContains: "Yahoo Mail", style: .formal),
        .anyBrowser(titleContains: "Google Docs", style: .formal),
        .anyBrowser(titleContains: "WhatsApp", style: .casual),
        .anyBrowser(titleContains: "Slack", style: .casual),
        .anyBrowser(titleContains: "Discord", style: .casual),
        .anyBrowser(titleContains: "Messenger", style: .casual),
        .anyBrowser(titleContains: "Telegram", style: .casual),
        .anyBrowser(titleContains: "Microsoft Teams", style: .casual),
        .anyBrowser(titleContains: "Google Chat", style: .casual),
    ]

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.rulesKey)
        }
    }

    /// Two rules target the same app + title scope (the uniqueness key).
    private static func sameTarget(_ a: AppStyleRule, _ b: AppStyleRule) -> Bool {
        guard a.bundleID.caseInsensitiveCompare(b.bundleID) == .orderedSame else { return false }
        switch (a.titleContains, b.titleContains) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default: return false
        }
    }

    /// Decodes an `AppStyleRule` but swallows a failure (e.g. an unknown style
    /// raw value) so one bad element never fails the whole array decode.
    private struct LenientRule: Decodable {
        let rule: AppStyleRule?
        init(from decoder: Decoder) throws {
            rule = try? AppStyleRule(from: decoder)
        }
    }
}
