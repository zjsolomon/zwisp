import Foundation

/// One permission's live status as the onboarding checklist sees it.
public enum PermissionStatus: Equatable {
    case granted
    /// Never asked — a system prompt is still possible.
    case notGranted
    /// Explicitly refused/restricted — only System Settings can fix it.
    /// Only the microphone reports this (`AVAuthorizationStatus.denied` /
    /// `.restricted`); the Input Monitoring and Accessibility check APIs can't
    /// distinguish "denied" from "not asked yet".
    case denied
}

/// The three permissions the setup guide walks through, with their display
/// copy. Kept in core so the strings live in one tested place.
public enum OnboardingPermission: String, CaseIterable, Equatable {
    case microphone = "Microphone"
    case inputMonitoring = "Input Monitoring"
    case accessibility = "Accessibility"

    public var title: String { rawValue }

    public var explanation: String {
        switch self {
        case .microphone:      return "Records your voice while you hold the key."
        case .inputMonitoring: return "Detects your push-to-talk key in any app."
        case .accessibility:   return "Types the transcribed text for you."
        }
    }

    /// The checklist row's action-button title for a given live status.
    public func buttonTitle(for status: PermissionStatus) -> String {
        switch (self, status) {
        case (_, .granted):
            return "Granted"
        case (.microphone, .notGranted):
            // The system prompt hasn't been burned yet — fire it directly.
            return "Allow…"
        default:
            return "Open Settings…"
        }
    }
}

/// Pure model of the first-run permission checklist. The app layer feeds it
/// live statuses (via `PermissionProbe`); everything derived from them — what's
/// missing, whether to auto-show the setup window, the menu-bar blame line —
/// lives here so it stays unit-tested.
public struct OnboardingState: Equatable {
    public var microphone: PermissionStatus
    public var inputMonitoring: PermissionStatus
    public var accessibility: PermissionStatus

    public init(microphone: PermissionStatus,
                inputMonitoring: PermissionStatus,
                accessibility: PermissionStatus) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    public func status(of permission: OnboardingPermission) -> PermissionStatus {
        switch permission {
        case .microphone:      return microphone
        case .inputMonitoring: return inputMonitoring
        case .accessibility:   return accessibility
        }
    }

    public var allGranted: Bool {
        OnboardingPermission.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// Auto-show the setup window at launch? Driven by the two hotkey
    /// permissions only: without them the app is inert (it can't even hear the
    /// hotkey), whereas the microphone's own system prompt is self-explanatory
    /// and fires on the first dictation attempt.
    public var needsSetup: Bool {
        inputMonitoring != .granted || accessibility != .granted
    }

    /// Names of the missing hotkey permissions, in checklist order — feeds the
    /// orange menu-bar tooltip so it blames the permission that's actually
    /// missing.
    public var missingHotkeyPermissionNames: [String] {
        var names: [String] = []
        if inputMonitoring != .granted { names.append(OnboardingPermission.inputMonitoring.title) }
        if accessibility != .granted { names.append(OnboardingPermission.accessibility.title) }
        return names
    }
}
