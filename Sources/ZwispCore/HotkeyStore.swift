import Foundation

/// The user's configured push-to-talk keys, persisted in `UserDefaults`.
///
/// Holding *any* configured key records; releasing it transcribes. Defaults to
/// Right ⌘ on first run. An explicitly emptied list is respected (recording is
/// simply not triggerable until the user adds one back).
public final class HotkeyStore {
    public private(set) var hotkeys: [Hotkey]

    private let defaults: UserDefaults
    static let key = "hotkeys"

    public static let defaultHotkeys: [Hotkey] = [.rightCommand]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.key) as? [Int] {
            // Key present (possibly an empty list the user cleared on purpose).
            self.hotkeys = HotkeyStore.decode(stored)
        } else {
            self.hotkeys = HotkeyStore.defaultHotkeys
        }
    }

    /// Adds a hotkey. Returns `false` (and does nothing) if it was already set.
    @discardableResult
    public func add(_ hotkey: Hotkey) -> Bool {
        guard !hotkeys.contains(hotkey) else { return false }
        hotkeys.append(hotkey)
        persist()
        return true
    }

    /// Removes a hotkey if present.
    public func remove(_ hotkey: Hotkey) {
        let before = hotkeys.count
        hotkeys.removeAll { $0 == hotkey }
        if hotkeys.count != before { persist() }
    }

    private func persist() {
        defaults.set(hotkeys.map { Int($0.rawValue) }, forKey: Self.key)
    }

    /// Maps stored mask values back to hotkeys, dropping any unrecognized ones.
    static func decode(_ stored: [Int]) -> [Hotkey] {
        stored.compactMap { Hotkey(rawValue: UInt64($0)) }
    }
}
