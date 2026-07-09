import SwiftUI
import ZwispCore

/// The Dictionary section: the exact-spelling word list plus the add field.
/// Ports the old Settings "Dictionary" tab onto the design system — the
/// `AddResult` feedback handling is unchanged.
struct DictionarySectionView: View {
    let model: SettingsModel
    @State private var newWord = ""
    @State private var feedback: DictionaryStore.AddResult?

    private func submit() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let result = model.addDictionaryWord(word)
        feedback = result
        if result == .added || result == .updated {
            newWord = ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Dictionary",
                          subtitle: "Names and terms zwisp should spell exactly your way.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    if model.dictionaryEntries.isEmpty {
                        Text("No words yet.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(Array(model.dictionaryEntries.enumerated()),
                            id: \.element) { index, word in
                        SettingRow(title: word,
                                   showsDivider: index != model.dictionaryEntries.count - 1) {
                            Button("Remove") { model.removeDictionaryWord(word) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack(spacing: Theme.spaceM) {
                        TextField("e.g. WhisperKit", text: $newWord)
                            .textFieldStyle(.plain)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.spaceM)
                            .padding(.vertical, 7)
                            .background(Theme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                            .onSubmit(submit)
                        Button("Add", action: submit)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    switch feedback {
                    case .rejected?:
                        Text(model.dictionaryRejectionMessage)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    case .duplicate?:
                        Text("Already in your dictionary.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .onChange(of: newWord) { feedback = nil }
    }
}
