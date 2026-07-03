import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid
import ZwispCore

/// The single place that reads live permission status and hosts the request
/// actions + System Settings deep links. Both `AppDelegate` and
/// `OnboardingWindow` go through it, so they can never disagree about what's
/// granted.
final class PermissionProbe {
    /// Non-prompting snapshot of all three permissions.
    func state() -> OnboardingState {
        OnboardingState(
            microphone: Self.microphoneStatus(),
            inputMonitoring: Self.inputMonitoringGranted() ? .granted : .notGranted,
            accessibility: AXIsProcessTrusted() ? .granted : .notGranted
        )
    }

    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:          return .granted
        case .denied, .restricted: return .denied   // only Settings can fix it
        case .notDetermined:       return .notGranted
        @unknown default:          return .notGranted
        }
    }

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // MARK: - Requests (fire the system prompt / register the app in the list)

    func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.write("microphone request result: \(granted)")
        }
    }

    /// Prompts and adds zwisp to the Input Monitoring list in Settings.
    func requestInputMonitoring() {
        let result = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Log.write("input monitoring request: \(result)")
    }

    /// Shows the system Accessibility nudge and adds zwisp to the list.
    func promptAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        Log.write("accessibility prompt shown (trusted=\(trusted))")
    }

    // MARK: - System Settings deep links

    func openMicrophoneSettings() { open("Privacy_Microphone") }
    func openInputMonitoringSettings() { open("Privacy_ListenEvent") }
    func openAccessibilitySettings() { open("Privacy_Accessibility") }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
