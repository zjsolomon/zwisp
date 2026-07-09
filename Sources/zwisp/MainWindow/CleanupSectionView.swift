import SwiftUI
import ZwispCore

/// The AI Cleanup section: the on/off toggle, the Ollama model picker, and the
/// live status line. Ports the old Settings "Cleanup" tab onto the design
/// system — the option/label logic is unchanged.
struct CleanupSectionView: View {
    let model: SettingsModel

    /// The model options: the fetched list, guaranteed to include the currently
    /// saved model even if Ollama doesn't report it (marked "(not installed)").
    private var modelOptions: [String] {
        var options = model.availableModels ?? []
        if !model.cleanupModel.isEmpty, !options.contains(model.cleanupModel) {
            options.append(model.cleanupModel)
        }
        return options
    }

    private func label(for name: String) -> String {
        if let installed = model.availableModels, !installed.contains(name) {
            return "\(name) (not installed)"
        }
        return name
    }

    /// The status dot beside the live status line, keyed off the same
    /// `CleanupService.status()` copy the line renders.
    private var statusKind: StatusKind {
        if !model.cleanupEnabled { return .off }
        return model.cleanupStatusLine.hasPrefix("Active") ? .ok : .attention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "AI Cleanup",
                          subtitle: "A local Ollama model tidies each transcript — fillers out, "
                                    + "punctuation in, your words conserved.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(title: "Clean up transcripts with Ollama",
                              caption: "Fails safe: if Ollama is unreachable or misbehaves, "
                                       + "the raw transcript is typed instead.",
                              showsDivider: true,
                              isOn: Binding(
                                get: { model.cleanupEnabled },
                                set: { model.setCleanupEnabled($0) }))

                    SettingRow(title: "Model") {
                        if model.availableModels == nil {
                            HStack(spacing: Theme.spaceS) {
                                ProgressView().controlSize(.small)
                                Text("Loading models…")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            Picker("", selection: Binding(
                                get: { model.cleanupModel },
                                set: { model.setCleanupModel($0) })) {
                                ForEach(modelOptions, id: \.self) { name in
                                    Text(label(for: name)).tag(name)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(!model.cleanupEnabled)
                        }
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
