import Testing
@testable import ZwhisperCore

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
}
