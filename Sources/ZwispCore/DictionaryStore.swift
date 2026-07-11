import Foundation

/// The user's personal dictionary — names and terms Whisper keeps mishearing
/// ("Ziedo", "WhisperKit") — persisted in `UserDefaults`.
///
/// Entries feed two consumers: the cleanup system prompt (the LLM is told the
/// exact spellings) and `TranscriptCorrector` (a deterministic post-pass that
/// works even when Ollama is off). Words arrive via the macOS Service ("Add to
/// zwisp Dictionary" on selected text), so `add` validates: a stray paragraph
/// selection must not become a "word".
public final class DictionaryStore {
    /// Insertion order, which is also prompt order. Use `sortedEntries` for UI.
    public private(set) var entries: [String]

    private let config: Configuration.PersonalDictionary
    private let defaults: UserDefaults
    static let key = "personalDictionary"

    /// First-run seed: the app's own name — it's lowercase, Whisper has never
    /// seen it, and it's the word every user dictates when talking about the
    /// app. Doubles as a visible example of what the dictionary is for.
    public static let defaultEntries = ["zwisp"]

    public init(config: Configuration.PersonalDictionary = Configuration.PersonalDictionary(),
                defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.key) {
            // Key present (possibly an empty list the user cleared on purpose).
            self.entries = stored
        } else {
            self.entries = Self.defaultEntries
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Case-insensitively sorted, for stable menu display.
    public var sortedEntries: [String] {
        entries.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// What `add` did with the text — callers surface these differently (the
    /// Service shows an error only for `.rejected`; `.duplicate` is a no-op).
    public enum AddResult: Equatable {
        case added            // new entry stored
        case updated          // existed with different casing; newest casing wins
        case duplicate        // already stored verbatim; nothing changed
        case rejected         // not dictionary material; nothing stored
    }

    /// Adds a trimmed entry. Rejects text that isn't dictionary material:
    /// empty, too long, or too many words. Re-adding an existing entry with
    /// different casing *replaces* it — the user is correcting the spelling.
    @discardableResult
    public func add(_ rawEntry: String) -> AddResult {
        let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty,
              entry.count <= config.maxEntryLength,
              entry.split(whereSeparator: \.isWhitespace).count <= config.maxEntryWords
        else { return .rejected }

        if let existing = entries.firstIndex(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
            guard entries[existing] != entry else { return .duplicate }
            entries[existing] = entry
            persist()
            return .updated
        }
        entries.append(entry)
        persist()
        return .added
    }

    /// Removes an entry if present (exact match — the menu passes back the
    /// stored string verbatim).
    public func remove(_ entry: String) {
        let before = entries.count
        entries.removeAll { $0 == entry }
        if entries.count != before { persist() }
    }

    private func persist() {
        defaults.set(entries, forKey: Self.key)
    }
}
