import SwiftUI
import ZwispCore

/// The Writing Styles section: the default style plus per-app rules. Ports the
/// old Settings "Writing Styles" tab onto the design system; the add-rule
/// sheet stays a sheet (it inherits the window's forced-dark appearance).
struct StylesSectionView: View {
    let model: SettingsModel
    @State private var showingAddRule = false
    /// Feedback line under the rule list after "Restore built-in rules".
    @State private var restoreNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Writing Styles",
                          subtitle: "Formal in Mail, casual in Slack — cleanup adapts to where "
                                    + "the text is going.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(title: "Default style",
                               caption: model.perAppStylesEnabled
                                   ? "Used wherever no rule below matches."
                                   : "Used for every dictation.",
                               showsDivider: true) {
                        Picker("", selection: Binding(
                            get: { model.defaultStyle },
                            set: { model.setDefaultStyle($0) })) {
                            ForEach(WritingStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    ToggleRow(title: "Per-app rules",
                              caption: "Pick a style by the app in front — and by the tab, in a browser.",
                              isOn: Binding(
                                get: { model.perAppStylesEnabled },
                                set: { model.setPerAppStylesEnabled($0) }))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Per-app rules")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    if model.rules.isEmpty {
                        Text("No rules — add one, or restore the built-in set.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(model.rules) { rule in
                        RuleRow(model: model, rule: rule)
                    }
                    HStack(spacing: Theme.spaceM) {
                        Button("Add Rule…") { showingAddRule = true }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Restore Built-in Rules") {
                            let added = model.restoreBuiltInRules()
                            restoreNote = added == 0
                                ? "All built-in rules are already in the list."
                                : "Restored \(added) built-in rule\(added == 1 ? "" : "s")."
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        if let restoreNote {
                            Text(restoreNote)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.top, Theme.spaceM)
                    Text("\u{201C}\(AppStyleRule.anyBrowserName)\u{201D} rules match the tab title in "
                         + "\(StyleResolver.browserNamesSummary). A rule for a specific browser "
                         + "wins over them. Restoring only adds what you removed.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.spaceM)
                }
                .opacity(model.perAppStylesEnabled ? 1 : 0.45)
                .disabled(!model.perAppStylesEnabled)
            }
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleSheet(model: model, isPresented: $showingAddRule)
        }
    }
}

/// One editable rule row, on a single line: app name + bundle ID, the "window
/// title contains" field (commits on Return or focus loss), a style picker, and
/// a remove button. Compact on purpose — the built-in set alone is ~25 rows.
private struct RuleRow: View {
    let model: SettingsModel
    let rule: AppStyleRule

    @State private var titleText: String
    @FocusState private var titleFocused: Bool

    init(model: SettingsModel, rule: AppStyleRule) {
        self.model = model
        self.rule = rule
        _titleText = State(initialValue: rule.titleContains ?? "")
    }

    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        guard newValue != rule.titleContains else { return }
        var updated = rule
        updated.titleContains = newValue
        model.updateRule(updated)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.isAnyBrowser ? AppStyleRule.anyBrowserName : rule.appName)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(rule.isAnyBrowser ? "by tab title" : rule.bundleID)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: Theme.spaceS)
            TextField(rule.isAnyBrowser ? "Tab title contains" : "Window title contains (optional)",
                      text: $titleText)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.spaceM)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 190)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
            Picker("", selection: Binding(
                get: { rule.style },
                set: { style in
                    var updated = rule
                    updated.style = style
                    model.updateRule(updated)
                })) {
                ForEach(WritingStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button("Remove") { model.removeRule(id: rule.id) }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
        }
    }
}

/// A pickable application (running or chosen from disk). Identifiable by bundle
/// ID so it can drive a `ForEach` — tuples can't (no key paths into tuples).
private struct AppChoice: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

/// Sheet for creating a rule: pick a running app (or one from disk), an optional
/// title substring, and a style. Kept close to stock controls — sheets behave
/// best with system form styling, and it inherits the window's dark appearance.
private struct AddRuleSheet: View {
    let model: SettingsModel
    @Binding var isPresented: Bool

    @State private var apps: [AppChoice] = []
    @State private var selectedBundleID: String = ""
    @State private var selectedName: String = ""
    @State private var titleContains: String = ""
    @State private var style: WritingStyle = .standard
    @State private var duplicateWarning = false

    private var canAdd: Bool { !selectedBundleID.isEmpty }

    private func loadApps() {
        apps = model.runningApps().map { AppChoice(name: $0.name, bundleID: $0.bundleID) }
        if selectedBundleID.isEmpty, let first = apps.first {
            selectedBundleID = first.bundleID
            selectedName = first.name
        }
    }

    private func selectName(for bundleID: String) {
        selectedName = apps.first { $0.bundleID == bundleID }?.name ?? selectedName
    }

    private func chooseFromDisk() {
        guard let picked = model.pickAppFromDisk() else { return }
        if !apps.contains(where: { $0.bundleID == picked.bundleID }) {
            apps.append(AppChoice(name: picked.name, bundleID: picked.bundleID))
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        selectedBundleID = picked.bundleID
        selectedName = picked.name
    }

    private func add() {
        let trimmed = titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = AppStyleRule(
            bundleID: selectedBundleID,
            appName: selectedName.isEmpty ? selectedBundleID : selectedName,
            titleContains: trimmed.isEmpty ? nil : trimmed,
            style: style)
        if model.addRule(rule) {
            isPresented = false
        } else {
            duplicateWarning = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Writing-Style Rule").font(.headline)

            Form {
                HStack {
                    Picker("Application", selection: $selectedBundleID) {
                        ForEach(apps) { app in
                            Text(app.name).tag(app.bundleID)
                        }
                    }
                    .onChange(of: selectedBundleID) { selectName(for: selectedBundleID) }
                    Button("Choose from disk…", action: chooseFromDisk)
                }

                TextField("When window title contains (optional)", text: $titleContains)

                Picker("Style", selection: $style) {
                    ForEach(WritingStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }
            .formStyle(.grouped)

            if duplicateWarning {
                Text("A rule for this app and title already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadApps)
        .onChange(of: titleContains) { duplicateWarning = false }
    }
}
