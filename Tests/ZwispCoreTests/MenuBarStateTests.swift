import Testing
import AppKit
@testable import ZwispCore

struct MenuBarStateTests {
    @Test func noPermissionWhenMonitorInactive() {
        #expect(MenuBarState.resting(monitorActive: false, modelReady: false,
                                     cleanup: .off) == .noPermission)
        #expect(MenuBarState.resting(monitorActive: false, modelReady: true,
                                     cleanup: .active(model: "m")) == .noPermission)
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
        #expect(MenuBarState.noPermission.tint == .systemOrange)
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
                      .recording, .thinking, .noPermission] {
            #expect(!state.label.isEmpty)
        }
    }
}
