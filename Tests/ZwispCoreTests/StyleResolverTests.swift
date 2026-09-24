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

    // MARK: - Any-browser rules

    private let gmailAnywhere = AppStyleRule.anyBrowser(titleContains: "Gmail", style: .formal)

    @Test func anyBrowserTitleRuleMatchesEveryKnownBrowser() {
        for browser in ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                        "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser"] {
            #expect(resolve(browser, "Inbox - Gmail", [gmailAnywhere]) == .formal,
                    "expected \(browser) to count as a browser")
        }
    }

    @Test func anyBrowserRuleIgnoresNonBrowsers() {
        // A Mail window mentioning Gmail is not a browser tab.
        #expect(resolve("com.apple.mail", "Gmail settings", [gmailAnywhere]) == .standard)
        // And the sentinel is never matched as a literal bundle ID.
        #expect(resolve(AppStyleRule.anyBrowserBundleID, "Gmail", [gmailAnywhere]) == .standard)
    }

    @Test func appSpecificRuleBeatsAnyBrowserRule() {
        // The user's own Safari rule wins over the generic one, whatever the
        // order — both for title rules…
        let safariGmail = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari",
                                       titleContains: "Gmail", style: .casual)
        #expect(resolve("com.apple.Safari", "Inbox - Gmail", [gmailAnywhere, safariGmail]) == .casual)
        #expect(resolve("com.apple.Safari", "Inbox - Gmail", [safariGmail, gmailAnywhere]) == .casual)
        // …and for bare rules.
        let safariBare = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari", style: .casual)
        let browserBare = AppStyleRule(bundleID: AppStyleRule.anyBrowserBundleID,
                                       appName: "Any", style: .formal)
        #expect(resolve("com.apple.Safari", "News", [browserBare, safariBare]) == .casual)
    }

    @Test func anyBrowserTitleRuleBeatsAppBareRule() {
        // Precedence is title-first across both groups: a Gmail tab in Safari
        // is formal even though Safari has a bare casual rule.
        let safariBare = AppStyleRule(bundleID: "com.apple.Safari", appName: "Safari", style: .casual)
        #expect(resolve("com.apple.Safari", "Inbox - Gmail", [safariBare, gmailAnywhere]) == .formal)
        #expect(resolve("com.apple.Safari", "News", [safariBare, gmailAnywhere]) == .casual)
    }

    @Test func browserSetIsCaseInsensitive() {
        #expect(StyleResolver.isBrowser("COM.APPLE.SAFARI"))
        #expect(!StyleResolver.isBrowser("com.apple.mail"))
    }
}
