import Foundation

/// A push-to-talk key.
///
/// Only *modifier* keys are supported: you hold one to record and release it to
/// transcribe, and modifiers (unlike letters) don't type characters or
/// auto-repeat while held. Each case's raw value is the **device-dependent**
/// modifier flag bit reported in a `flagsChanged` event, which is what lets us
/// tell Left ⌘ apart from Right ⌘ (the general `.maskCommand` bit can't).
public enum Hotkey: UInt64, CaseIterable, Sendable {
    case leftControl  = 0x0000_0001  // NX_DEVICELCTLKEYMASK
    case leftShift    = 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
    case rightShift   = 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
    case leftCommand  = 0x0000_0008  // NX_DEVICELCMDKEYMASK
    case rightCommand = 0x0000_0010  // NX_DEVICERCMDKEYMASK
    case leftOption   = 0x0000_0020  // NX_DEVICELALTKEYMASK
    case rightOption  = 0x0000_0040  // NX_DEVICERALTKEYMASK
    case rightControl = 0x0000_2000  // NX_DEVICERCTLKEYMASK
    case fn           = 0x0080_0000  // kCGEventFlagMaskSecondaryFn (Globe / 🌐)

    /// The flag bit to test against a `flagsChanged` event's `flags.rawValue`.
    public var mask: UInt64 { rawValue }

    /// Human-readable label shown in the menu.
    public var name: String {
        switch self {
        case .leftControl:  return "Left ⌃ Control"
        case .leftShift:    return "Left ⇧ Shift"
        case .rightShift:   return "Right ⇧ Shift"
        case .leftCommand:  return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption:   return "Left ⌥ Option"
        case .rightOption:  return "Right ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .fn:           return "Fn 🌐 (Globe)"
        }
    }
}
