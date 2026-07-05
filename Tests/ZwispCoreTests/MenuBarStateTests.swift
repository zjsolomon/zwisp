import Testing
import AppKit
@testable import ZwispCore

struct MenuBarStateTests {
    @Test func noPermissionWhenMonitorInactive() {
        #expect(MenuBarState.resting(monitorActive: false, modelReady: false,
                                     cleanup: .off) == .noPermission(missing: []))
        #expect(MenuBarState.resting(monitorActive: false, modelReady: true,
                                     cleanup: .active(model: "m")) == .noPermission(missing: []))
    }

    @Test func noPermissionCarriesTheMissingNames() {
        #expect(MenuBarState.resting(monitorActive: false, modelReady: true,
                                     cleanup: .off,
                                     missingPermissions: ["Input Monitoring"])
                == .noPermission(missing: ["Input Monitoring"]))
        // Equality is sensitive to the associated value.
        #expect(MenuBarState.noPermission(missing: ["Accessibility"])
                != .noPermission(missing: ["Input Monitoring"]))
    }

    @Test func noPermissionLabelNamesTheMissingPermissions() {
        // Exactly the trap this exists for: only Input Monitoring missing must
        // NOT be reported as an Accessibility problem.
        let one = MenuBarState.noPermission(missing: ["Input Monitoring"]).label
        #expect(one.contains("Input Monitoring"))
        #expect(!one.contains("Accessibility"))
        #expect(one.contains("permission:"))

        let both = MenuBarState.noPermission(missing: ["Input Monitoring", "Accessibility"]).label
        #expect(both.contains("Input Monitoring"))
        #expect(both.contains("Accessibility"))
        #expect(both.contains("permissions:"))

        // Generic fallback when the caller couldn't name the culprit.
        #expect(!MenuBarState.noPermission(missing: []).label.isEmpty)
    }

    @Test func loadingWhenMonitorActiveButModelNotReady() {
        #expect(MenuBarState.resting(monitorActive: true, modelReady: false,
                                     cleanup: .off) == .loading)
        // Cleanup readiness must not mask that dictation itself isn't ready.
        #expect(MenuBarState.resting(monitorActive: true, modelReady: false,
                                     cleanup: .active(model: "m")) == .loading)
    }

    @Test func readyCarriesTheCleanupStatus() {
        #expect(MenuBarState.resting(monitorActive: true, modelReady: true,
                                     cleanup: .off) == .ready(cleanup: .off))
        #expect(MenuBarState.resting(monitorActive: true, modelReady: true,
                                     cleanup: .active(model: "qwen3:4b-instruct"))
                == .ready(cleanup: .active(model: "qwen3:4b-instruct")))
    }

    @Test func tintsFollowTheColourScheme() {
        // red = warming up, green = ready without cleanup, blue = ready with
        // cleanup, orange = permissions missing.
        #expect(MenuBarState.loading.tint == .systemRed)
        #expect(MenuBarState.ready(cleanup: .off).tint == .systemGreen)
        #expect(MenuBarState.ready(cleanup: .unavailable).tint == .systemGreen)
        #expect(MenuBarState.ready(cleanup: .active(model: "m")).tint == .systemBlue)
        #expect(MenuBarState.noPermission(missing: []).tint == .systemOrange)
        #expect(MenuBarState.noPermission(missing: ["Accessibility"]).tint == .systemOrange)
    }

    @Test func recordingUsesTemplateImage() {
        // nil tint => template image: recording adds no colour of its own,
        // macOS's microphone-in-use indicator is the recording signal.
        #expect(MenuBarState.recording.tint == nil)
    }

    @Test func activeCleanupLabelNamesTheModel() {
        #expect(MenuBarState.ready(cleanup: .active(model: "qwen3:4b-instruct"))
            .label.contains("qwen3:4b-instruct"))
    }

    @Test func everyStateHasNonEmptyLabel() {
        for state in [MenuBarState.loading, .ready(cleanup: .off),
                      .ready(cleanup: .unavailable), .ready(cleanup: .active(model: "m")),
                      .recording, .thinking, .noPermission(missing: []),
                      .noPermission(missing: ["Input Monitoring"])] {
            #expect(!state.label.isEmpty)
        }
    }
}
