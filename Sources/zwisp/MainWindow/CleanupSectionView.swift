import SwiftUI
import ZwispCore

/// The AI Cleanup section: the on/off toggle, the bundled model, and the live
/// status line. The engine (a llama-server inside zwisp.app) serves one pinned
/// model — there's nothing to pick and nothing to install beyond the model
/// file, which the Setup section downloads.
struct CleanupSectionView: View {
    let model: SettingsModel

    /// The status dot beside the live status line, keyed off the same
    /// `CleanupService.status()` copy the line renders.
    private var statusKind: StatusKind {
        if !model.cleanupEnabled { return .off }
        return model.cleanupStatusLine.hasPrefix("Active") ? .ok : .attention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "AI Cleanup",
                          subtitle: "A local model tidies each transcript — fillers out, "
                                    + "punctuation in, your words conserved.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(title: "Clean up transcripts",
                              caption: "Fails safe: if the engine is unavailable or misbehaves, "
                                       + "the raw transcript is typed instead.",
                              showsDivider: true,
                              isOn: Binding(
                                get: { model.cleanupEnabled },
                                set: { model.setCleanupEnabled($0) }))

                    SettingRow(title: "Model") {
                        Text("\(model.cleanupModelName) — runs inside zwisp")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if !model.cleanupStatusLine.isEmpty {
                        HStack(spacing: Theme.spaceS) {
                            PixelStatusDot(kind: statusKind)
                            Text(model.cleanupStatusLine)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.top, Theme.spaceXS)
                    }
                }
            }
        }
    }
}
