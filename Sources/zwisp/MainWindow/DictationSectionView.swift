import SwiftUI
import ZwispCore

/// The Dictation section: push-to-talk keys, the on-screen wave toggle, Launch
/// at Login, and the speech model in use. Ports the old Settings "General" tab
/// onto the design system, unchanged in behaviour.
struct DictationSectionView: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Dictation",
                          subtitle: "Hold a key, talk, release — the text is typed where your cursor is.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Push-to-talk keys")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    if model.hotkeys.isEmpty {
                        Text("No hotkey set — add one to start dictating.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(model.hotkeys, id: \.self) { hotkey in
                        SettingRow(title: hotkey.name, showsDivider: true) {
                            Button("Remove") { model.removeHotkey(hotkey) }
                                .buttonStyle(SecondaryButtonStyle())
                                // The app needs at least one key; never remove
                                // the last.
                                .disabled(model.hotkeys.count <= 1)
                                .opacity(model.hotkeys.count <= 1 ? 0.4 : 1)
                        }
                    }
                    Button("Add Hotkey…") { model.addHotkey() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Theme.spaceM)
                    Text("Adding a hotkey opens a capture panel — this window may "
                         + "lose focus while you press and hold the key you want.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.spaceM)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleRow(title: "Show wave while dictating",
                              caption: "The little equalizer near the bottom of the screen.",
                              showsDivider: true,
                              isOn: Binding(
                                get: { model.overlayEnabled },
                                set: { model.setOverlayEnabled($0) }))
                    ToggleRow(title: "Launch at Login",
                              isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { _ in model.toggleLaunchAtLogin() }))
                }
            }

            Card {
                SettingRow(title: "Speech model",
                           caption: "On-device via WhisperKit; nothing leaves your Mac.") {
                    Text("\(model.speechModelName) — runs on this Mac")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
