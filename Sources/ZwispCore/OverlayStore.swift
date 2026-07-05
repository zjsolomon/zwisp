import Foundation

/// Persists whether the user wants the dictation-wave overlay shown, in
/// `UserDefaults`. Mirrors `CleanupService.enabled` semantics: an **absent key
/// means enabled** (the feature is on by default; the store only records the
/// user's explicit choice to turn it off), and each write is persisted
/// immediately via `didSet`.
public final class OverlayStore {
    static let key = "overlayEnabled"

    private let defaults: UserDefaults

    /// Whether the overlay should be shown. Persisted on every change.
    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.key) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key → default on. `object(forKey:)` distinguishes "never set"
        // (nil → true) from an explicit `false` the user chose.
        if let stored = defaults.object(forKey: Self.key) as? Bool {
            self.enabled = stored
        } else {
            self.enabled = true
        }
    }
}
