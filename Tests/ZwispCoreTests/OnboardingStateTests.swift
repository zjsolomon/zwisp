import Testing
@testable import ZwispCore

struct OnboardingStateTests {
    /// All granted unless overridden — tests tweak one axis at a time.
    private func state(mic: PermissionStatus = .granted,
                       input: PermissionStatus = .granted,
                       ax: PermissionStatus = .granted) -> OnboardingState {
        OnboardingState(microphone: mic, inputMonitoring: input, accessibility: ax)
    }

    @Test func allGrantedOnlyWhenAllThreeAreGranted() {
        #expect(state().allGranted)
        #expect(!state(mic: .notGranted).allGranted)
        #expect(!state(mic: .denied).allGranted)
        #expect(!state(input: .notGranted).allGranted)
        #expect(!state(ax: .notGranted).allGranted)
    }

    @Test func needsSetupWhenEitherHotkeyPermissionIsMissing() {
        #expect(state(input: .notGranted).needsSetup)
        #expect(state(ax: .notGranted).needsSetup)
        #expect(state(input: .notGranted, ax: .notGranted).needsSetup)
        #expect(!state().needsSetup)
    }

    @Test func microphoneAloneDoesNotForceSetup() {
        // The mic's own system prompt is self-explanatory; the window is only
        // auto-shown for the permissions that leave the app inert.
        #expect(!state(mic: .notGranted).needsSetup)
        #expect(!state(mic: .denied).needsSetup)
    }

    @Test func missingNamesListInputMonitoringBeforeAccessibility() {
        #expect(state(input: .notGranted, ax: .notGranted).missingHotkeyPermissionNames
                == ["Input Monitoring", "Accessibility"])
        #expect(state(input: .notGranted).missingHotkeyPermissionNames == ["Input Monitoring"])
        #expect(state(ax: .notGranted).missingHotkeyPermissionNames == ["Accessibility"])
    }

    @Test func missingNamesIgnoreTheMicrophone() {
        #expect(state(mic: .denied).missingHotkeyPermissionNames.isEmpty)
        #expect(state().missingHotkeyPermissionNames.isEmpty)
    }

    @Test func statusOfMapsEachPermission() {
        let s = state(mic: .denied, input: .notGranted, ax: .granted)
        #expect(s.status(of: .microphone) == .denied)
        #expect(s.status(of: .inputMonitoring) == .notGranted)
        #expect(s.status(of: .accessibility) == .granted)
    }

    @Test func micButtonOffersThePromptUntilItIsBurned() {
        // Not asked yet → the system prompt can still fire directly.
        #expect(OnboardingPermission.microphone.buttonTitle(for: .notGranted) == "Allow…")
        // Previously refused → only System Settings can fix it.
        #expect(OnboardingPermission.microphone.buttonTitle(for: .denied) == "Open Settings…")
        #expect(OnboardingPermission.microphone.buttonTitle(for: .granted) == "Granted")
    }

    @Test func hotkeyPermissionButtonsGoStraightToSettings() {
        for permission in [OnboardingPermission.inputMonitoring, .accessibility] {
            #expect(permission.buttonTitle(for: .notGranted) == "Open Settings…")
            #expect(permission.buttonTitle(for: .granted) == "Granted")
        }
    }

    @Test func everyPermissionHasDisplayCopy() {
        for permission in OnboardingPermission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.explanation.isEmpty)
        }
    }
}
