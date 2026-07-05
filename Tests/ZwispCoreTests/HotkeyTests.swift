import Testing
@testable import ZwispCore

struct HotkeyTests {
    @Test func rightCommandMaskMatchesDeviceFlagBit() {
        // NX_DEVICERCMDKEYMASK
        #expect(Hotkey.rightCommand.mask == 0x10)
        #expect(Hotkey.fn.mask == 0x0080_0000)
    }

    @Test func rawValueRoundTrips() {
        for hotkey in Hotkey.allCases {
            #expect(Hotkey(rawValue: hotkey.rawValue) == hotkey)
        }
    }

    @Test func allMasksAreDistinct() {
        let masks = Hotkey.allCases.map(\.mask)
        #expect(Set(masks).count == masks.count)
    }

    @Test func everyHotkeyHasANonEmptyName() {
        for hotkey in Hotkey.allCases {
            #expect(!hotkey.name.isEmpty)
        }
    }

    // MARK: - held(of:flags:keyCode:previouslyHeld:) — phantom-Fn filtering

    private let upArrowKeyCode: Int64 = 126

    @Test func genuineFnPressIsHeld() {
        let held = Hotkey.held(
            of: [.fn], flags: Hotkey.fn.mask, keyCode: Hotkey.fnKeyCode, previouslyHeld: [])
        #expect(held == [.fn])
    }

    @Test func arrowKeySettingFnBitDoesNotPressFn() {
        // Arrow/navigation keys set the Fn flag bit with their own keycode —
        // must not start recording.
        let held = Hotkey.held(
            of: [.fn], flags: Hotkey.fn.mask, keyCode: upArrowKeyCode, previouslyHeld: [])
        #expect(held.isEmpty)
    }

    @Test func arrowKeyClearingFnBitDoesNotReleaseHeldFn() {
        // While genuinely holding Fn, arrow-key flag noise must not fire a
        // phantom release mid-dictation.
        let held = Hotkey.held(
            of: [.fn], flags: 0, keyCode: upArrowKeyCode, previouslyHeld: [.fn])
        #expect(held == [.fn])
    }

    @Test func genuineFnReleaseClearsIt() {
        let held = Hotkey.held(
            of: [.fn], flags: 0, keyCode: Hotkey.fnKeyCode, previouslyHeld: [.fn])
        #expect(held.isEmpty)
    }

    @Test func nonFnHotkeysIgnoreKeyCodeEntirely() {
        // Right ⌘ is identified purely by its device flag bit.
        let held = Hotkey.held(
            of: [.rightCommand], flags: Hotkey.rightCommand.mask, keyCode: 999,
            previouslyHeld: [])
        #expect(held == [.rightCommand])
    }

    @Test func mixedHotkeysFilterOnlyTheFnBit() {
        // Holding Right ⌘ while an arrow key flips the Fn bit: ⌘ stays held,
        // Fn stays un-held.
        let flags = Hotkey.rightCommand.mask | Hotkey.fn.mask
        let held = Hotkey.held(
            of: [.rightCommand, .fn], flags: flags, keyCode: upArrowKeyCode,
            previouslyHeld: [.rightCommand])
        #expect(held == [.rightCommand])
    }

    // MARK: - newlyPressed(flags:previousFlags:keyCode:) — capture mode

    @Test func newlyPressedReportsGenuineFn() {
        #expect(Hotkey.newlyPressed(
            flags: Hotkey.fn.mask, previousFlags: 0, keyCode: Hotkey.fnKeyCode) == .fn)
    }

    @Test func newlyPressedIgnoresArrowInducedFn() {
        #expect(Hotkey.newlyPressed(
            flags: Hotkey.fn.mask, previousFlags: 0, keyCode: upArrowKeyCode) == nil)
    }

    @Test func newlyPressedReportsOtherModifiersRegardlessOfKeyCode() {
        #expect(Hotkey.newlyPressed(
            flags: Hotkey.leftOption.mask, previousFlags: 0, keyCode: 61) == .leftOption)
    }
}

struct InjectionGateTests {
    private let config = Configuration.Injection(quietWindow: 0.4, maxInjectionWait: 10)

    private func canInject(recording: Bool = false, sinceKey: Double = 5,
                           modifiers: Bool = false, waited: Double = 0) -> Bool {
        Configuration.InjectionGate.canInject(
            isRecording: recording, secondsSinceKeyEvent: sinceKey,
            modifiersDown: modifiers, waited: waited, config: config)
    }

    @Test func injectsWhenKeyboardIsQuiet() {
        #expect(canInject(sinceKey: 0.5))
    }

    @Test func waitsWhileUserIsTyping() {
        #expect(!canInject(sinceKey: 0.1))
    }

    @Test func waitsWhileRecording() {
        // The next dictation is being spoken — never type into it.
        #expect(!canInject(recording: true, sinceKey: 5))
    }

    @Test func waitsWhileModifierHeld() {
        // Injecting with ⌘ held would fire the app's shortcuts.
        #expect(!canInject(sinceKey: 5, modifiers: true))
    }

    @Test func waitCapOverridesTypingButNotModifiers() {
        // Nonstop typing can't starve the dictation forever…
        #expect(canInject(sinceKey: 0.1, waited: 11))
        // …but a held modifier or open mic still blocks even past the cap.
        #expect(!canInject(sinceKey: 5, modifiers: true, waited: 11))
        #expect(!canInject(recording: true, sinceKey: 5, waited: 11))
    }
}
