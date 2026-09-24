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

    // MARK: - Per-app toggle

    @Test func perAppRulesDefaultOnAndPersist() {
        let defaults = freshDefaults()
        let store = StyleRuleStore(defaults: defaults)
        #expect(store.perAppEnabled)
        store.perAppEnabled = false
        #expect(StyleRuleStore(defaults: defaults).perAppEnabled == false)
    }

    @Test func disabledRulesResolveToDefaultStyle() {
        let store = StyleRuleStore(defaults: freshDefaults())
        store.add(AppStyleRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: .casual))
        store.defaultStyle = .formal
        #expect(store.resolve(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .casual)
        store.perAppEnabled = false
        #expect(store.resolve(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .formal)
        // The rules themselves are kept for when it is switched back on.
        #expect(store.rules.count == 1)
        store.perAppEnabled = true
        #expect(store.resolve(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .casual)
    }

    // MARK: - Built-in rules

    @Test func builtInRulesHaveUniqueTargetsAndNeverUseStandard() {
        var seen = Set<String>()
        for rule in StyleRuleStore.builtInRules {
            let target = rule.bundleID.lowercased() + "|" + (rule.titleContains?.lowercased() ?? "")
            #expect(seen.insert(target).inserted, "duplicate built-in target \(target)")
            // A standard rule would be a no-op against the standard default.
            #expect(rule.style != .standard)
            // Any-browser built-ins are always title-scoped.
            if rule.isAnyBrowser { #expect(rule.titleContains != nil) }
        }
        #expect(StyleRuleStore.builtInRules.count >= 20)
    }

    @Test func seedingFillsAFreshStoreOnce() {
        let defaults = freshDefaults()
        let store = StyleRuleStore(defaults: defaults)
        #expect(store.seedBuiltInRulesIfNeeded() == StyleRuleStore.builtInRules.count)
        #expect(store.rules.count == StyleRuleStore.builtInRules.count)
        // Idempotent within and across instances.
        #expect(store.seedBuiltInRulesIfNeeded() == 0)
        #expect(StyleRuleStore(defaults: defaults).seedBuiltInRulesIfNeeded() == 0)
    }

    @Test func seedingKeepsExistingRulesAndSkipsTheirTargets() {
        let store = StyleRuleStore(defaults: freshDefaults())
        // The user already has WhatsApp → formal (unusual, but theirs).
        let mine = AppStyleRule(bundleID: "NET.WHATSAPP.WHATSAPP", appName: "WhatsApp", style: .formal)
        store.add(mine)
        store.seedBuiltInRulesIfNeeded()
        #expect(store.rules.count == StyleRuleStore.builtInRules.count)
        #expect(store.rules.first?.id == mine.id)
        #expect(store.resolve(bundleID: "net.whatsapp.WhatsApp", windowTitle: nil) == .formal)
    }

    @Test func removedBuiltInStaysRemovedButRestoreBringsItBack() {
        let defaults = freshDefaults()
        let store = StyleRuleStore(defaults: defaults)
        store.seedBuiltInRulesIfNeeded()
        let slack = try! #require(store.rules.first { $0.bundleID == "com.tinyspeck.slackmacgap" })
        store.remove(id: slack.id)
        // A relaunch must not resurrect it…
        let relaunched = StyleRuleStore(defaults: defaults)
        relaunched.seedBuiltInRulesIfNeeded()
        #expect(!relaunched.rules.contains { $0.bundleID == "com.tinyspeck.slackmacgap" })
        // …only the explicit restore does, adding just what is missing.
        #expect(relaunched.addMissingBuiltInRules() == 1)
        #expect(relaunched.rules.contains { $0.bundleID == "com.tinyspeck.slackmacgap" })
        #expect(relaunched.addMissingBuiltInRules() == 0)
    }

    @Test func seededStoreResolvesTheCommonCases() {
        let store = StyleRuleStore(defaults: freshDefaults())
        store.seedBuiltInRulesIfNeeded()
        #expect(store.resolve(bundleID: "com.apple.mail", windowTitle: "Inbox") == .formal)
        #expect(store.resolve(bundleID: "com.apple.MobileSMS", windowTitle: nil) == .casual)
        #expect(store.resolve(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@gmail.com - Gmail") == .formal)
        #expect(store.resolve(bundleID: "com.microsoft.edgemac", windowTitle: "Mail - Ziedo - Outlook") == .formal)
        #expect(store.resolve(bundleID: "com.apple.Safari", windowTitle: "WhatsApp") == .casual)
        #expect(store.resolve(bundleID: "com.apple.Safari", windowTitle: "BBC News") == .standard)
        #expect(store.resolve(bundleID: "com.apple.TextEdit", windowTitle: "Untitled") == .standard)
    }
}
