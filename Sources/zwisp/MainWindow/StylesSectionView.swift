import SwiftUI
import ZwispCore

/// The Writing Styles section: the default style plus per-app rules. Ports the
/// old Settings "Writing Styles" tab onto the design system; the add-rule
/// sheet stays a sheet (it inherits the window's forced-dark appearance).
struct StylesSectionView: View {
    let model: SettingsModel
    @State private var showingAddRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Writing Styles",
                          subtitle: "Formal in Mail, casual in Slack — cleanup adapts to where "
                                    + "the text is going.")

            Card {
                SettingRow(title: "Default style") {
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
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Per-app rules")
                        .font(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, Theme.spaceXS)
                    if model.rules.isEmpty {
                        Text("No rules yet — add one to override the default for a specific app.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(model.rules) { rule in
                        RuleRow(model: model, rule: rule)
                    }
                    Button("Add Rule…") { showingAddRule = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Theme.spaceM)
                    Text("Example: Safari with title containing \u{201C}Gmail\u{201D} \u{2192} "
                         + "Formal applies only in Gmail tabs.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.spaceM)
                }
            }
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleSheet(model: model, isPresented: $showingAddRule)
        }
    }
}

/// One editable rule row: app name + bundle ID, a "window title contains" field
/// (commits on Return or focus loss), a style picker, and a remove button.
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
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.appName)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(rule.bundleID)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
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
            }
            TextField("When window title contains (optional)", text: $titleText)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.spaceM)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
        }
        .padding(.vertical, 10)
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
