import Foundation

/// The sections of the unified main window, one per sidebar row. Kept in core so
/// the titles and SF Symbol names live in one tested place, and so navigation
/// decisions stay unit-testable without a window.
public enum MainSection: String, CaseIterable, Equatable, Sendable {
    case home, setup, dictation, cleanup, dictionary, styles

    public var title: String {
        switch self {
        case .home:       return "Home"
        case .setup:      return "Setup"
        case .dictation:  return "Dictation"
        case .cleanup:    return "AI Cleanup"
        case .dictionary: return "Dictionary"
        case .styles:     return "Writing Styles"
        }
    }

    /// SF Symbol for the sidebar row.
    public var symbolName: String {
        switch self {
        case .home:       return "house"
        case .setup:      return "checklist"
        case .dictation:  return "waveform"
        case .cleanup:    return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .styles:     return "text.alignleft"
        }
    }
}

/// Pure navigation decisions for the main window.
public enum MainNav {
    /// Whether Setup should flag for attention — mirrors the launch auto-show
    /// gate: the two hotkey permissions missing (via `OnboardingState.needsSetup`,
    /// which excludes the microphone) OR the speech model not yet on disk. The
    /// optional cleanup-model download never counts here.
    public static func setupNeedsAttention(permissions: OnboardingState,
                                           speechModelInstalled: Bool) -> Bool {
        permissions.needsSetup || !speechModelInstalled
    }

    /// Which section the window opens on: Setup when it needs attention, else Home.
    public static func launchSection(needsAttention: Bool) -> MainSection {
        needsAttention ? .setup : .home
    }
}
