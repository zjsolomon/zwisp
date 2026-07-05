import SwiftUI
import ZwispCore

/// The Settings UI: a four-tab SwiftUI form hosted by `SettingsWindow`. Each tab
/// is a small private subview reading from — and mutating through — the shared
/// `SettingsModel`. Styling stays deliberately plain (standard macOS Form /
/// GroupBox); the model owns all the store/side-effect plumbing.
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupTab(model: model)
                .tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            DictionaryTab(model: model)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            WritingStylesTab(model: model)
                .tabItem { Label("Writing Styles", systemImage: "text.alignleft") }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Push-to-talk keys") {
                if model.hotkeys.isEmpty {
                    Text("No hotkey set — add one to start dictating.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hotkeys, id: \.self) { hotkey in
                    HStack {
                        Text(hotkey.name)
                        Spacer()
                        Button("Remove") { model.removeHotkey(hotkey) }
                            // The app needs at least one key; never remove the last.
                            .disabled(model.hotkeys.count <= 1)
                    }
                }
                Button("Add Hotkey…") { model.addHotkey() }
                Text("Adding a hotkey opens a capture panel — this window may lose "
                     + "focus while you press and hold the key you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLaunchAtLogin() }))
                Button("Setup Guide…") { model.openSetupGuide() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cleanup

private struct CleanupTab: View {
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

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts with Ollama", isOn: Binding(
                    get: { model.cleanupEnabled },
                    set: { model.setCleanupEnabled($0) }))

                if model.availableModels == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Model", selection: Binding(
                        get: { model.cleanupModel },
                        set: { model.setCleanupModel($0) })) {
                        ForEach(modelOptions, id: \.self) { name in
                            Text(label(for: name)).tag(name)
                        }
                    }
                    .disabled(!model.cleanupEnabled)
                }

                if !model.cleanupStatusLine.isEmpty {
                    Text(model.cleanupStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Models in use") {
                LabeledContent("Speech recognition", value: model.whisperModel)
                LabeledContent("Cleanup",
                               value: model.cleanupEnabled ? model.cleanupModel : "—")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
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
        Form {
            Section("Words zwisp should spell exactly") {
                if model.dictionaryEntries.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                }
                ForEach(model.dictionaryEntries, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button("Remove") { model.removeDictionaryWord(word) }
                    }
                }
            }

            Section {
                HStack {
                    TextField("e.g. WhisperKit", text: $newWord)
                        .onSubmit(submit)
                    Button("Add", action: submit)
                        .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                switch feedback {
                case .rejected?:
                    Text(model.dictionaryRejectionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                case .duplicate?:
                    Text("Already in your dictionary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: newWord) { feedback = nil }
    }
}

// MARK: - Writing Styles

private struct WritingStylesTab: View {
    let model: SettingsModel
    @State private var showingAddRule = false

    var body: some View {
        Form {
            Section("Default style") {
                Picker("Default", selection: Binding(
                    get: { model.defaultStyle },
                    set: { model.setDefaultStyle($0) })) {
                    ForEach(WritingStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Section("Per-app rules") {
                if model.rules.isEmpty {
                    Text("No rules yet — add one to override the default for a specific app.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    RuleRow(model: model, rule: rule)
                }
                Button("Add Rule…") { showingAddRule = true }
                Text("Example: Safari with title containing \u{201C}Gmail\u{201D} \u{2192} "
                     + "Formal applies only in Gmail tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.appName)
                    Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
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
            }
            TextField("When window title contains (optional)", text: $titleText)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
        }
        .padding(.vertical, 2)
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
/// title substring, and a style.
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
