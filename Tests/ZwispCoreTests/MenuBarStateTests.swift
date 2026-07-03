import Testing
import AppKit
@testable import ZwispCore

struct MenuBarStateTests {
    @Test func noPermissionWhenMonitorInactive() {
        #expect(MenuBarState.resting(monitorActive: false, modelReady: false) == .noPermission)
        #expect(MenuBarState.resting(monitorActive: false, modelReady: true) == .noPermission)
    }

    @Test func loadingWhenMonitorActiveButModelNotReady() {
        #expect(MenuBarState.resting(monitorActive: true, modelReady: false) == .loading)
    }

    @Test func idleWhenBothReady() {
        #expect(MenuBarState.resting(monitorActive: true, modelReady: true) == .idle)
    }

    @Test func idleUsesTemplateImage() {
        // nil tint => template image that macOS tints for the menu bar.
        #expect(MenuBarState.idle.tint == nil)
        #expect(MenuBarState.recording.tint != nil)
    }

    @Test func everyStateHasNonEmptyLabel() {
        for state in [MenuBarState.loading, .idle, .recording, .thinking, .noPermission] {
            #expect(!state.label.isEmpty)
        }
    }
}
