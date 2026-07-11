import Foundation

/// Deterministic post-pass that fixes personal-dictionary terms in a final
/// transcript. It runs *after* the optional LLM cleanup pass (which may or may
/// not have already fixed the term) as a last, predictable safety net: Whisper
/// routinely mishears names and jargon the user cares about ("Ziedo" → "zeedo",
/// "WhisperKit" → "whisper kit"), and this restores the exact spelling the user
/// registered.
///
/// The guiding principle is the dictionary's own: **a wrong "correction" is
/// worse than a missed one.** Everything here is biased towards leaving text
/// alone unless the match is close and unambiguous:
///   - short entries never fuzzy-match (edit distance turns everyday words into
///     names — "data" → "Dana"); they only fix casing or a split-word join,
///   - a window that already spells *another* dictionary entry is never
///     fuzzy-rewritten into a near neighbour,
///   - exact (casing/join) matches always beat fuzzy ones.
///
/// Matching normalises both sides the way `CleanupService.normalizedWords`
/// does — lowercased, letters and digits only — so casing and attached
/// punctuation don't hide an otherwise perfect match. Replacement, by contrast,
/// only ever touches the matched *word run*: leading/trailing punctuation and
/// all surrounding whitespace are preserved verbatim, so `"ask zeedo."` becomes
/// `"ask Ziedo."` and never `"ask Ziedo"`.
///
/// Pure `ZwispCore` logic (Foundation only), so it is fully unit-tested.
public enum TranscriptCorrector {
    /// One applied substitution, for surfacing to the user / logging. `original`
    /// is the exact transcript run that was replaced (its outer punctuation is
    /// *not* included); `replacement` is the dictionary entry's exact form.
    public struct Correction: Equatable {
        public let original: String
        public let replacement: String

        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }

    /// The corrected text plus every substitution made, in reading order.
    public struct Result {
        public let text: String
        public let corrections: [Correction]

        public init(text: String, corrections: [Correction]) {
            self.text = text
            self.corrections = corrections
        }
    }

    /// Fixes personal-dictionary terms in `text`. Returns the input unchanged
    /// (with no corrections) when there is nothing to do — empty text or an
    /// empty dictionary.
    public static func correct(
        _ text: String,
        dictionary: [String],
        config: Configuration.PersonalDictionary = Configuration.PersonalDictionary()
    ) -> Result {
        guard !text.isEmpty, !dictionary.isEmpty else {
            return Result(text: text, corrections: [])
        }

        let entries = makeEntries(from: dictionary)
        guard !entries.isEmpty else { return Result(text: text, corrections: []) }
        // Every entry's normalized form, so the fuzzy stage can refuse to
        // rewrite a window that is already an *exact* spelling of some entry.
        let entryForms = Set(entries.map { $0.normalized })

        let tokens = tokenize(text)
        // Word slots in reading order: their index into `tokens`, surface text,
        // and normalized form. Matching slides windows over these; the gaps and
        // punctuation between them stay in `tokens` untouched.
        let words: [Word] = tokens.enumerated().compactMap { index, token in
            guard case .word(let surface) = token else { return nil }
            return Word(tokenIndex: index, surface: surface, normalized: normalize(surface))
        }

        var corrections: [Correction] = []
        // tokenIndex of a replaced run's first token -> (last token index, text).
        var replacements: [Int: (last: Int, text: String)] = [:]

        // Scan left-to-right, non-overlapping: a word consumed by a match can't
        // participate in a later one, so on a hit we jump past the whole window.
        var w = 0
        while w < words.count {
            guard let match = bestMatch(at: w, words: words, entries: entries,
                                        entryForms: entryForms, config: config) else {
                w += 1
                continue
            }

            let firstToken = words[w].tokenIndex
            let lastToken = words[w + match.wordCount - 1].tokenIndex
            let original = tokens[firstToken...lastToken].map { $0.text }.joined()
            // Casing matches on already-correct text are silently consumed (so a
            // fuzzy rule can't later "fix" a correct word) but not reported.
            if original != match.replacement {
                replacements[firstToken] = (last: lastToken, text: match.replacement)
                corrections.append(Correction(original: original, replacement: match.replacement))
            }
            w += match.wordCount
        }

        guard !corrections.isEmpty else { return Result(text: text, corrections: []) }
        return Result(text: render(tokens: tokens, replacements: replacements),
                      corrections: corrections)
    }

    // MARK: - Matching

    /// The winning substitution for the window starting at word `w`, or `nil`.
    /// Exact matches (casing, or a split-word join) always beat fuzzy ones;
    /// among fuzzy candidates the lowest edit distance wins, ties going to the
    /// earlier dictionary entry.
    private static func bestMatch(
        at w: Int, words: [Word], entries: [Entry],
        entryForms: Set<String>, config: Configuration.PersonalDictionary
    ) -> Match? {
        var exact: Match?
        var fuzzy: Match?

        for entry in entries {
            // Exact / fuzzy over a window the size of the entry's own word count.
            if w + entry.wordCount <= words.count {
                let join = words[w..<w + entry.wordCount].map { $0.normalized }.joined()
                if join == entry.normalized {
                    // Casing fix — earliest entry wins a tie.
                    if exact == nil {
                        exact = Match(wordCount: entry.wordCount, replacement: entry.surface)
                    }
                } else if entry.normalized.count >= config.fuzzyMinLength,
                          // Safety rail: never fuzzy-rewrite a window that is
                          // already the exact spelling of some dictionary entry.
                          !entryForms.contains(join) {
                    let allowed = entry.normalized.count >= config.fuzzyTwoEditMinLength ? 2 : 1
                    let distance = damerauLevenshtein(Array(join), Array(entry.normalized))
                    if distance >= 1, distance <= allowed,
                       distance < (fuzzy?.distance ?? Int.max) {
                        fuzzy = Match(wordCount: entry.wordCount,
                                      replacement: entry.surface, distance: distance)
                    }
                }
            }

            // Join fix: a one-word entry split across two adjacent transcript
            // words ("whisper kit" -> "WhisperKit"). Exact concatenation only.
            if entry.wordCount == 1, exact == nil, w + 2 <= words.count {
                let join = words[w].normalized + words[w + 1].normalized
                if join == entry.normalized {
                    exact = Match(wordCount: 2, replacement: entry.surface)
                }
            }
        }

        return exact ?? fuzzy
    }

    // MARK: - Tokenizing

    /// A run of text: either a `word` (maximal run of letters/digits, the unit
    /// matching slides over) or a `gap` (whitespace and punctuation, preserved
    /// verbatim). Splitting words off from everything else is what lets a
    /// replacement keep the comma or bracket that was clinging to a misheard
    /// name.
    private enum Token {
        case word(String)
        case gap(String)

        var text: String {
            switch self {
            case .word(let s), .gap(let s): return s
            }
        }
    }

    private struct Word {
        let tokenIndex: Int
        let surface: String
        let normalized: String
    }

    private struct Entry {
        let surface: String     // the user's exact spelling
        let normalized: String  // lowercased, letters/digits only
        let wordCount: Int      // whitespace-separated word count
    }

    private struct Match {
        let wordCount: Int      // transcript words the window spans
        let replacement: String
        var distance: Int = 0   // 0 for exact matches
    }

    /// Splits `text` into alternating word / gap runs, losing nothing: the
    /// concatenation of every token's text reproduces the input exactly.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false

        for ch in text {
            let isWord = ch.isLetter || ch.isNumber
            if current.isEmpty {
                current = String(ch)
                currentIsWord = isWord
            } else if isWord == currentIsWord {
                current.append(ch)
            } else {
                tokens.append(currentIsWord ? .word(current) : .gap(current))
                current = String(ch)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty {
            tokens.append(currentIsWord ? .word(current) : .gap(current))
        }
        return tokens
    }

    /// Prepares the dictionary for matching: normalises each entry and records
    /// its word count, dropping entries that normalise to nothing (pure
    /// punctuation), which could never be a meaningful match.
    private static func makeEntries(from dictionary: [String]) -> [Entry] {
        dictionary.compactMap { raw in
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return nil }
            let wordCount = raw
                .split(whereSeparator: { $0.isWhitespace })
                .map(normalize)
                .filter { !$0.isEmpty }
                .count
            return Entry(surface: raw, normalized: normalized, wordCount: max(wordCount, 1))
        }
    }

    /// Rebuilds the transcript, swapping each replaced word run for its
    /// dictionary spelling and passing every other token through untouched.
    private static func render(tokens: [Token],
                              replacements: [Int: (last: Int, text: String)]) -> String {
        var result = ""
        var i = 0
        while i < tokens.count {
            if let replacement = replacements[i] {
                result += replacement.text
                i = replacement.last + 1
            } else {
                result += tokens[i].text
                i += 1
            }
        }
        return result
    }

    /// Lowercased, letters and digits only — mirrors
    /// `CleanupService.normalizedWords` so casing and attached punctuation never
    /// hide a match.
    private static func normalize<S: StringProtocol>(_ text: S) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Edit distance

    /// Damerau–Levenshtein distance (optimal string alignment) between two
    /// character arrays: single-edit insertions, deletions, substitutions, and
    /// adjacent transpositions. Transpositions matter because a common Whisper
    /// slip is swapping neighbouring letters, and counting that as one edit
    /// rather than two keeps a genuine mishearing inside the threshold.
    static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1,      // deletion
                              d[i][j - 1] + 1,      // insertion
                              d[i - 1][j - 1] + cost)  // substitution
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)  // transposition
                }
            }
        }
        return d[m][n]
    }
}
