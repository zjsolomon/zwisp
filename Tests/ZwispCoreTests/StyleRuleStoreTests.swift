import Foundation
import Testing
@testable import ZwispCore

struct StyleRuleStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
    }

    // MARK: - Fresh state

    @Test func startsEmptyWithStandardDefault() {
        let store = StyleRuleStore(defaults: freshDefaults())
        #expect(store.rules.isEmpty)
        #expect(store.defaultStyle == .standard)
    }

    // MARK: - add / update / remove

    @Test func addStoresRuleAndRejectsDuplicateTarget() {
        let store = StyleRuleStore(defaults: freshDefaults())
        let slack = AppStyleRule(bundleID: "com.tinyspeck.slackmacgap",
                                 appName: "Slack", style: .casual)
        #expect(store.add(slack) == true)
        #expect(store.rules.count == 1)

        // Same (bundleID, titleContains) pair — case-insensitively — is a dup,
        // even with a different id/style.
        let dup = AppStyleRule(bundleID: "COM.TINYSPECK.SLACKMACGAP",
                               appName: "Slack", style: .formal)
        #expect(store.add(dup) == false)
        #expect(store.rules.count == 1)
    }

    @Test func addAllowsSameAppWithDifferentTitleScope() {
        let store = StyleRuleStore(defaults: freshDefaults())
        let bare = AppStyleRule(bundleID: "com.apple.Safari",
                                appName: "Safari", style: .standard)
        let gmail = AppStyleRule(bundleID: "com.apple.Safari",
                                 appName: "Safari", titleContains: "Gmail", style: .formal)
        #expect(store.add(bare) == true)
        #expect(store.add(gmail) == true)
        #expect(store.rules.count == 2)
    }

    @Test func updateReplacesRuleById() {
        let store = StyleRuleStore(defaults: freshDefaults())
        var rule = AppStyleRule(bundleID: "com.apple.Mail", appName: "Mail", style: .formal)
        store.add(rule)
        rule.style = .casual
        store.update(rule)
        #expect(store.rules.first?.style == .casual)
        #expect(store.rules.count == 1)
    }

    @Test func removeDeletesById() {
        let store = StyleRuleStore(defaults: freshDefaults())
        let rule = AppStyleRule(bundleID: "com.apple.Mail", appName: "Mail", style: .formal)
        store.add(rule)
        store.remove(id: rule.id)
        #expect(store.rules.isEmpty)
        // Removing a missing id is a no-op.
        store.remove(id: UUID())
        #expect(store.rules.isEmpty)
    }

    // MARK: - Persistence

    @Test func rulesAndDefaultPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = StyleRuleStore(defaults: defaults)
        first.add(AppStyleRule(bundleID: "com.tinyspeck.slackmacgap",
                               appName: "Slack", style: .casual))
        first.add(AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                               titleContains: "Gmail", style: .formal))
        first.defaultStyle = .formal

        let second = StyleRuleStore(defaults: defaults)
        #expect(second.defaultStyle == .formal)
        #expect(second.rules.count == 2)
        #expect(second.rules.contains { $0.bundleID == "com.apple.Safari" && $0.titleContains == "Gmail" })
    }

    // MARK: - Lenient decode

    @Test func rulesWithUnknownStyleAreDroppedOthersLoad() throws {
        let defaults = freshDefaults()
        // Two rules: one with an unknown style raw value, one valid. The invalid
        // rule must be dropped without failing the whole array decode.
        let json = """
        [
          {"id":"\(UUID().uuidString)","bundleID":"com.future.app","appName":"Future","style":"telepathic"},
          {"id":"\(UUID().uuidString)","bundleID":"com.tinyspeck.slackmacgap","appName":"Slack","style":"casual"}
        ]
        """
        defaults.set(Data(json.utf8), forKey: StyleRuleStore.rulesKey)

        let store = StyleRuleStore(defaults: defaults)
        #expect(store.rules.count == 1)
        #expect(store.rules.first?.bundleID == "com.tinyspeck.slackmacgap")
        #expect(store.rules.first?.style == .casual)
    }

    @Test func unknownDefaultStyleFallsBackToStandard() {
        let defaults = freshDefaults()
        defaults.set("telepathic", forKey: StyleRuleStore.defaultStyleKey)
        let store = StyleRuleStore(defaults: defaults)
        #expect(store.defaultStyle == .standard)
    }
}
