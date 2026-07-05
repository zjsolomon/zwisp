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
}

/// Pure resolution of a frontmost-app snapshot to a `WritingStyle`. Split out so
/// the precedence rules are unit-testable without any AppKit/AX plumbing.
public enum StyleResolver {
    /// Resolves the style for a frontmost app.
    ///
    /// Precedence, among the rules whose `bundleID` matches (case-insensitively):
    /// a title rule whose substring occurs (case-insensitively) in
    /// `windowTitle` wins over a bare rule *regardless of array order*; among
    /// title rules, the first match wins. A title rule never matches a `nil`
    /// window title (an AX read failure degrades gracefully to the bare rule).
    /// A `nil` `bundleID` or no matching rule falls through to `defaultStyle`.
    public static func resolve(bundleID: String?, windowTitle: String?,
                               rules: [AppStyleRule], defaultStyle: WritingStyle) -> WritingStyle {
        guard let bundleID else { return defaultStyle }
        let matching = rules.filter {
            $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }

        // Title rules take precedence over bare rules; first match wins.
        if let windowTitle {
            for rule in matching {
                if let needle = rule.titleContains, !needle.isEmpty,
                   windowTitle.range(of: needle, options: .caseInsensitive) != nil {
                    return rule.style
                }
            }
        }

        // No title rule matched — fall back to the first bare rule for the app.
        if let bare = matching.first(where: { $0.titleContains == nil }) {
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

    /// The style used when no rule matches. Persisted on set.
    public var defaultStyle: WritingStyle {
        didSet { defaults.set(defaultStyle.rawValue, forKey: Self.defaultStyleKey) }
    }

    private let defaults: UserDefaults
    static let rulesKey = "styleRules"
    static let defaultStyleKey = "defaultWritingStyle"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultStyleKey),
           let style = WritingStyle(rawValue: raw) {
            self.defaultStyle = style
        } else {
            self.defaultStyle = .standard
        }
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
    /// default.
    public func resolve(bundleID: String?, windowTitle: String?) -> WritingStyle {
        StyleResolver.resolve(bundleID: bundleID, windowTitle: windowTitle,
                              rules: rules, defaultStyle: defaultStyle)
    }

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
