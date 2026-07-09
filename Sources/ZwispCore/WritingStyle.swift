import Foundation

/// The writing style a dictation is cleaned into. Resolved once at record time
/// from the frontmost app (see `StyleRuleStore`/`StyleResolver`) and threaded
/// through `CleanupService.clean(_:style:)`.
///
/// Steering happens entirely in the cleanup *system* prompt: each style
/// contributes a `promptBlock` appended after the base prompt and the personal
/// dictionary (see `Configuration.Cleanup.systemPrompt`). `.standard` adds
/// nothing, so its rendered prompt is byte-identical to the pre-styles prompt.
///
/// Persisted as its raw string; unknown raw values are dropped leniently on
/// load, so a future custom style never corrupts a user's stored rules.
public enum WritingStyle: String, CaseIterable, Codable, Sendable {
    case standard
    case formal
    case casual

    /// Menu / picker label.
    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .formal: return "Formal (email)"
        case .casual: return "Casual (chat)"
        }
    }

    /// The style-specific instructions appended to the cleanup system prompt,
    /// or `nil` for `.standard` (which leaves the base prompt untouched).
    ///
    /// Formal is *format-only*: it reshapes what was dictated into email layout
    /// and punctuation but never invents greetings, sign-offs, or any word the
    /// speaker didn't say — the conservation rule the whole prompt rests on
    /// stays intact. Casual has to fight the base few-shot examples (all
    /// capitalized and punctuated), so it explicitly overrides those
    /// conventions and carries its own lowercase counter-examples.
    public var promptBlock: String? {
        switch self {
        case .standard:
            return nil
        case .formal:
            return """
            WRITING STYLE — FORMAL (this dictation is going into a formal \
            context such as an email):
            In addition to the rules above: write complete, correctly \
            punctuated sentences and break the text into short paragraphs \
            (blank line between them) at natural topic shifts. If the speaker \
            dictated a greeting ("hi sarah", "dear team"), put it on its own \
            line ending with a comma, followed by a blank line. If they \
            dictated a closing ("thanks", "best regards" and/or their name), \
            put it on its own line(s) at the end. The conservation rule still \
            applies in full: never add a greeting, closing, or any words the \
            speaker did not say, and never formalize their word choices — this \
            style changes layout and punctuation only.
            Example:
            Input: hi sarah um just wanted to follow up on the contract could \
            you send the signed copy by friday thanks ziedo
            Output: Hi Sarah,\\n\\nJust wanted to follow up on the contract. \
            Could you send the signed copy by Friday?\\n\\nThanks,\\nZiedo
            """
        case .casual:
            return """
            WRITING STYLE — CASUAL CHAT (this dictation is going into an \
            informal chat such as Slack or WhatsApp):
            For THIS dictation, the capitalization and punctuation conventions \
            shown in the examples above are replaced by relaxed chat style:
            - all lowercase, including "i", names, and sentence starts
            - no period at the end of a sentence or message; keep question \
            marks, and use commas only where the sentence is hard to read \
            without one
            - keep apostrophes in contractions ("i'll", "don't")
            Everything else above still applies unchanged: remove only fillers, \
            stutters, and revoked corrections; keep every other word the \
            speaker said, in order; convert dictated punctuation, numbers, and \
            times to written form.
            Examples:
            Input: hey um can you send me the link to the doc
            Output: hey can you send me the link to the doc
            Input: sounds good ill be there at five thirty
            Output: sounds good, i'll be there at 5:30
            Input: did you see toms message question mark thats wild
            Output: did you see tom's message? that's wild
            """
        }
    }
}
