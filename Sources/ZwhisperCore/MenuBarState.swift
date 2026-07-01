import AppKit

/// The menu-bar item's visible state. Kept separate from `AppDelegate` so the
/// state-derivation logic can be unit-tested without spinning up an app.
public enum MenuBarState: Equatable {
    case loading      // model loading
    case idle         // ready, waiting for Fn
    case recording    // Fn held, capturing audio
    case thinking     // transcribing
    case noPermission // accessibility / input monitoring not granted

    /// Derives the resting state from the two independent readiness signals.
    /// Only meaningful when no recording/transcription is in progress.
    public static func resting(monitorActive: Bool, modelReady: Bool) -> MenuBarState {
        if !monitorActive { return .noPermission }
        if !modelReady { return .loading }
        return .idle
    }

    public var label: String {
        switch self {
        case .loading:      return "Loading model…"
        case .idle:         return "Ready — hold Fn to talk"
        case .recording:    return "Recording…"
        case .thinking:     return "Transcribing…"
        case .noPermission: return "Needs Accessibility permission"
        }
    }

    /// nil = template image (auto black/white to match the menu bar).
    public var tint: NSColor? {
        switch self {
        case .idle:         return nil
        case .loading:      return .secondaryLabelColor
        case .recording:    return .systemRed
        case .thinking:     return .systemBlue
        case .noPermission: return .systemOrange
        }
    }
}
