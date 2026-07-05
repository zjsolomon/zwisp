import AppKit
import SwiftUI
import ZwispCore

/// The first-run setup UI: a single scrollable grouped Form hosted by
/// `SetupWindow`. Sections walk the user through the three permissions, the
/// speech-model download, and the optional AI-cleanup chain (Ollama + model).
/// Rows read live snapshots from — and forward taps through — the shared
/// `SetupModel`. Styling follows `SettingsView` (standard macOS grouped Form).
/// User-facing copy that isn't already in core lives here (SettingsView
/// precedent).
struct SetupView: View {
    let model: SetupModel
    /// Injected by the window so the footer's "Done" button can close it.
    let dismiss: () -> Void

    var body: some View {
        Form {
            headerSection
            permissionsSection
            dictationSection
            cleanupSection
            if model.permissions.allGranted {
                footerSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to zwisp")
                        .font(.title2).bold()
                    Text("A few steps and you're dictating everywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            ForEach(OnboardingPermission.allCases, id: \.self) { permission in
                let status = model.permissions.status(of: permission)
                let granted = (status == .granted)
                HStack(spacing: 10) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(permission.title)
                        Text(permission.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(permission.buttonTitle(for: status)) {
                        model.tapPermission(permission)
                    }
                    .disabled(granted)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Dictation engine

    private var dictationSection: some View {
        Section("Dictation engine") {
            installRow(title: "Speech model",
                       phase: model.speechPhase,
                       onRetry: { model.retrySpeechDownload() })
        }
    }

    // MARK: - AI cleanup (optional)

    private var cleanupSection: some View {
        Section("AI cleanup (optional)") {
            installRow(title: "Ollama",
                       phase: model.ollamaPhase,
                       onRetry: { model.retryCleanupSetup() })
            installRow(title: model.cleanupModelName,
                       phase: model.cleanupModelPhase,
                       onRetry: { model.retryCleanupSetup() })
            if let title = model.cleanupActionTitle {
                Button(title) { model.runCleanupAction() }
            }
            Text("Other models: Settings → Cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.readyMessage)
                    .font(.callout)
                    .fontWeight(.semibold)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Shared install row

    /// One dependency row: title + `statusLine` caption, with a trailing
    /// determinate/indeterminate `ProgressView` while installing and a "Retry"
    /// button when failed. Matches the old onboarding's row layout in SwiftUI.
    @ViewBuilder
    private func installRow(title: String,
                            phase: InstallPhase,
                            onRetry: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(phase.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch phase {
            case .installing(_, let fraction):
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                Button("Retry", action: onRetry)
            case .missing, .installed:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}
