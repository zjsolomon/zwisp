import Foundation
import Testing
@testable import ZwispCore

struct OverlayStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
    }

    @Test func defaultsToEnabledWhenKeyAbsent() {
        // Absent key means the feature is on — the store only records an opt-out.
        let store = OverlayStore(defaults: freshDefaults())
        #expect(store.enabled)
    }

    @Test func togglePersistsAcrossInstances() {
        let defaults = freshDefaults()
        let first = OverlayStore(defaults: defaults)
        first.enabled = false

        let second = OverlayStore(defaults: defaults)
        #expect(!second.enabled)
    }
}
