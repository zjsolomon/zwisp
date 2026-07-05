import Foundation
import Testing
@testable import ZwispCore

struct StyleResolverTests {
    private func resolve(_ bundleID: String?, _ title: String?,
                         _ rules: [AppStyleRule], default def: WritingStyle = .standard) -> WritingStyle {
        StyleResolver.resolve(bundleID: bundleID, windowTitle: title,
                              rules: rules, defaultStyle: def)
    }

    private let slack = AppStyleRule(bundleID: "com.tinyspeck.slackmacgap",
                                     appName: "Slack", style: .casual)

    @Test func noRulesReturnsDefault() {
        #expect(resolve("com.apple.Mail", "Inbox", [], default: .formal) == .formal)
    }

    @Test func nilBundleIDReturnsDefault() {
        #expect(resolve(nil, "Inbox", [slack], default: .formal) == .formal)
    }

    @Test func noMatchingRuleReturnsDefault() {
        #expect(resolve("com.apple.Mail", "Inbox", [slack]) == .standard)
    }

    @Test func bareRuleMatchesRegardlessOfTitle() {
        #expect(resolve("com.tinyspeck.slackmacgap", "anything", [slack]) == .casual)
        #expect(resolve("com.tinyspeck.slackmacgap", nil, [slack]) == .casual)
    }

    @Test func bundleIDCompareIsCaseInsensitive() {
        #expect(resolve("COM.TINYSPECK.SlackMacGap", "x", [slack]) == .casual)
    }

    @Test func titleMatchIsCaseInsensitive() {
        let gmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                 titleContains: "Gmail", style: .formal)
        #expect(resolve("com.apple.Safari", "Inbox (24) - me@gmail.com - GMAIL", [gmail]) == .formal)
    }

    @Test func titleRuleNeverMatchesNilTitle() {
        // An AX read failure (nil title) must degrade to the default, not the
        // title rule.
        let gmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                 titleContains: "Gmail", style: .formal)
        #expect(resolve("com.apple.Safari", nil, [gmail]) == .standard)
    }

    @Test func titleRuleBeatsBareRuleRegardlessOfOrder() {
        let bare = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari", style: .standard)
        let gmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                 titleContains: "Gmail", style: .formal)
        // Bare listed first…
        #expect(resolve("com.apple.Safari", "My Gmail", [bare, gmail]) == .formal)
        // …and bare listed second: title rule still wins.
        #expect(resolve("com.apple.Safari", "My Gmail", [gmail, bare]) == .formal)
    }

    @Test func titleRuleWithNonMatchingTitleFallsThroughToBareRule() {
        let bare = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari", style: .casual)
        let gmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                 titleContains: "Gmail", style: .formal)
        #expect(resolve("com.apple.Safari", "News - BBC", [gmail, bare]) == .casual)
    }

    @Test func firstMatchingTitleRuleWins() {
        let gmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                 titleContains: "Gmail", style: .formal)
        let mail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                titleContains: "mail", style: .casual)
        // "Gmail" contains both needles; the first rule in order wins.
        #expect(resolve("com.apple.Safari", "My Gmail", [gmail, mail]) == .formal)
        #expect(resolve("com.apple.Safari", "My Gmail", [mail, gmail]) == .casual)
    }
}
