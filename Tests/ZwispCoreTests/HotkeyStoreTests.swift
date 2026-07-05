import Testing
import Foundation
@testable import ZwispCore

struct HotkeyStoreTests {
    /// A fresh, isolated defaults suite so tests never touch real preferences.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispHotkeyTests-\(UUID().uuidString)")!
    }

    @Test func defaultsToRightCommandOnFirstRun() {
        let store = HotkeyStore(defaults: freshDefaults())
        #expect(store.hotkeys == [.rightCommand])
    }

    @Test func addAppendsAndDedupes() {
        let store = HotkeyStore(defaults: freshDefaults())
        #expect(store.add(.fn) == true)
        #expect(store.hotkeys == [.rightCommand, .fn])
        // Adding an existing key is a no-op and reports false.
        #expect(store.add(.fn) == false)
        #expect(store.hotkeys == [.rightCommand, .fn])
    }

    @Test func removeDropsTheKey() {
        let store = HotkeyStore(defaults: freshDefaults())
        store.add(.leftOption)
        store.remove(.rightCommand)
        #expect(store.hotkeys == [.leftOption])
    }

    @Test func changesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = HotkeyStore(defaults: defaults)
        first.add(.fn)
        first.remove(.rightCommand)

        let reloaded = HotkeyStore(defaults: defaults)
        #expect(reloaded.hotkeys == [.fn])
    }

    @Test func anExplicitlyEmptiedListIsRespected() {
        let defaults = freshDefaults()
        let store = HotkeyStore(defaults: defaults)
        store.remove(.rightCommand)          // now empty, and persisted as empty
        #expect(store.hotkeys.isEmpty)

        // A reload must NOT resurrect the default — the user cleared it on purpose.
        let reloaded = HotkeyStore(defaults: defaults)
        #expect(reloaded.hotkeys.isEmpty)
    }
}
