import Testing
@testable import ZwispCore

struct MainNavTests {
    private func permissions(mic: PermissionStatus = .granted,
                             input: PermissionStatus = .granted,
                             ax: PermissionStatus = .granted) -> OnboardingState {
        OnboardingState(microphone: mic, inputMonitoring: input, accessibility: ax)
    }

    @Test func attentionWhenAHotkeyPermissionIsMissing() {
        #expect(MainNav.setupNeedsAttention(permissions: permissions(input: .notGranted),
                                            speechModelInstalled: true))
        #expect(MainNav.setupNeedsAttention(permissions: permissions(ax: .notGranted),
                                            speechModelInstalled: true))
    }

    @Test func attentionWhenSpeechModelMissing() {
        #expect(MainNav.setupNeedsAttention(permissions: permissions(),
                                            speechModelInstalled: false))
    }

    @Test func noAttentionWhenGrantedAndInstalled() {
        #expect(!MainNav.setupNeedsAttention(permissions: permissions(),
                                             speechModelInstalled: true))
    }

    @Test func microphoneAloneDoesNotFlagAttention() {
        // Mirrors `OnboardingState.needsSetup`: the mic is excluded (its own
        // prompt fires on first dictation).
        #expect(!MainNav.setupNeedsAttention(permissions: permissions(mic: .notGranted),
                                             speechModelInstalled: true))
        #expect(!MainNav.setupNeedsAttention(permissions: permissions(mic: .denied),
                                             speechModelInstalled: true))
    }

    @Test func launchSectionPicksSetupOnlyWhenNeeded() {
        #expect(MainNav.launchSection(needsAttention: true) == .setup)
        #expect(MainNav.launchSection(needsAttention: false) == .home)
    }

    @Test func sectionTitlesAreStable() {
        #expect(MainSection.home.title == "Home")
        #expect(MainSection.setup.title == "Setup")
        #expect(MainSection.dictation.title == "Dictation")
        #expect(MainSection.cleanup.title == "AI Cleanup")
        #expect(MainSection.dictionary.title == "Dictionary")
        #expect(MainSection.styles.title == "Writing Styles")
    }

    @Test func everySectionHasTitleAndSymbol() {
        for section in MainSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }
}
