import AppKit
import SwiftUI
import ZwispCore

/// The Setup section: the three permissions, the speech-model download, and
/// the optional AI-cleanup chain. A straight port of the old `SetupView` into
/// the design system — same `SetupModel` reads and intents, with pixel status
/// dots for the checklist and `PixelProgressBar` for installs. The old footer
/// "Done" closed the window; here it navigates Home.
struct SetupSectionView: View {
    let model: MainWindowModel

    private var setup: SetupModel { model.setup }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Setup",
                          subtitle: "A few steps and you're dictating everywhere.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Permissions")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    ForEach(Array(OnboardingPermission.allCases.enumerated()),
                            id: \.element) { index, permission in
                        permissionRow(permission,
                                      isLast: index == OnboardingPermission.allCases.count - 1)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Dictation engine")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    installRow(title: "Speech model",
                               phase: setup.speechPhase,
                               onRetry: { setup.retrySpeechDownload() })
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("AI cleanup (optional)")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    // Ollama is a service, not an artifact: its row reads
                    // "Running"/"Not running" (a Homebrew CLI install has no app
                    // bundle, so install wording would call a working server
                    // missing).
                    installRow(title: "Ollama",
                               phase: setup.ollamaPhase,
                               status: setup.ollamaPhase.serverStatusLine,
                               showsDivider: true,
                               onRetry: { setup.retryCleanupSetup() })
                    installRow(title: setup.cleanupModelName,
                               phase: setup.cleanupModelPhase,
                               onRetry: { setup.retryCleanupSetup() })
                    if let title = setup.cleanupActionTitle {
                        Button(title) { setup.runCleanupAction() }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.top, Theme.spaceM)
                    }
                    Text("Other models: the AI Cleanup section.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.spaceM)
                }
            }

            if setup.permissions.allGranted {
                Card {
                    HStack(spacing: Theme.spaceM) {
                        Text(setup.readyMessage)
                            .font(Theme.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button("Go to Home") { model.select(.home) }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func permissionRow(_ permission: OnboardingPermission, isLast: Bool) -> some View {
        let status = setup.permissions.status(of: permission)
        let granted = (status == .granted)
        HStack(spacing: Theme.spaceM) {
            PixelStatusDot(kind: granted ? .ok : .off)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(permission.explanation)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(permission.buttonTitle(for: status)) {
                setup.tapPermission(permission)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(granted)
            .opacity(granted ? 0.4 : 1)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            }
        }
    }

    /// One dependency row: title + status caption (defaults to the phase's
    /// install wording; the Ollama row passes `serverStatusLine` instead), with
    /// a trailing pixel progress bar while installing and a "Retry" button when
    /// failed.
    @ViewBuilder
    private func installRow(title: String,
                            phase: InstallPhase,
                            status: String? = nil,
                            showsDivider: Bool = false,
                            onRetry: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.spaceM) {
            PixelStatusDot(kind: dotKind(for: phase))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(status ?? phase.statusLine)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            switch phase {
            case .installing(_, let fraction):
                PixelProgressBar(fraction: fraction)
                    .frame(width: 140)
            case .failed:
                Button("Retry", action: onRetry)
                    .buttonStyle(SecondaryButtonStyle())
            case .missing, .installed:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            }
        }
    }

    private func dotKind(for phase: InstallPhase) -> StatusKind {
        switch phase {
        case .installed: return .ok
        case .installing: return .busy
        case .failed: return .attention
        case .missing: return .off
        }
    }
}
