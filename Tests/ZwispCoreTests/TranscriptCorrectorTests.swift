import Testing
import Foundation
@testable import ZwispCore

struct TranscriptCorrectorTests {
    // Default config: fuzzyMinLength 5, fuzzyTwoEditMinLength 8. Short names
    // (like "Zied") are deliberately fuzzy-ineligible under the defaults.
    private let defaults = Configuration.PersonalDictionary()

    // MARK: - Exact / casing

    @Test func casingFixRestoresRegisteredSpelling() {
        let result = TranscriptCorrector.correct("i love whisperkit", dictionary: ["WhisperKit"])
        #expect(result.text == "i love WhisperKit")
        #expect(result.corrections == [.init(original: "whisperkit", replacement: "WhisperKit")])
    }

    @Test func alreadyCorrectTextReturnsNoCorrections() {
        let result = TranscriptCorrector.correct("i love WhisperKit", dictionary: ["WhisperKit"])
        #expect(result.text == "i love WhisperKit")
        #expect(result.corrections.isEmpty)
    }

    // MARK: - Join

    @Test func joinFixMergesSplitWord() {
        let result = TranscriptCorrector.correct("try whisper kit today", dictionary: ["WhisperKit"])
        #expect(result.text == "try WhisperKit today")
        #expect(result.corrections == [.init(original: "whisper kit", replacement: "WhisperKit")])
    }

    // MARK: - Fuzzy

    @Test func fuzzyMatchFixesMisheardName() {
        // "Zied" is only 4 letters, so it needs a lowered fuzzy threshold to be
        // eligible at all — exactly the tradeoff its config knob exposes.
        let config = Configuration.PersonalDictionary(fuzzyMinLength: 4)
        let result = TranscriptCorrector.correct("call zeed", dictionary: ["Zied"], config: config)
        #expect(result.text == "call Zied")
        #expect(result.corrections == [.init(original: "zeed", replacement: "Zied")])
    }

    @Test func fuzzyMatchFixesMisheardMultiWordName() {
        // Normalized "ziedsolomon" is 11 chars, so 2 edits are tolerated and the
        // name is eligible under the *defaults*.
        let result = TranscriptCorrector.correct("email zeed solomon",
                                                 dictionary: ["Zied Solomon"])
        #expect(result.text == "email Zied Solomon")
        #expect(result.corrections == [.init(original: "zeed solomon", replacement: "Zied Solomon")])
    }

    // MARK: - Punctuation preservation

    @Test func punctuationSurvivesAroundReplacement() {
        let config = Configuration.PersonalDictionary(fuzzyMinLength: 4)
        let result = TranscriptCorrector.correct("ask zeed.", dictionary: ["Zied"], config: config)
        #expect(result.text == "ask Zied.")
        #expect(result.corrections == [.init(original: "zeed", replacement: "Zied")])
    }

    @Test func surroundingBracketsAndQuotesSurvive() {
        let result = TranscriptCorrector.correct("(whisperkit) is \"whisperkit\"",
                                                 dictionary: ["WhisperKit"])
        #expect(result.text == "(WhisperKit) is \"WhisperKit\"")
    }

    // MARK: - Negative / safety

    @Test func shortEntryDoesNotCaptureCommonWords() {
        // Under the defaults "Zied" is fuzzy-ineligible, so nearby everyday
        // words ("died", "tried") are left completely alone.
        let result = TranscriptCorrector.correct("he died and tried again",
                                                 dictionary: ["Zied"], config: defaults)
        #expect(result.text == "he died and tried again")
        #expect(result.corrections.isEmpty)
    }

    @Test func entriesBelowFuzzyMinLengthNeverFuzzyMatch() {
        // "Cat" normalizes to 3 chars, below fuzzyMinLength, so "car" is safe.
        let result = TranscriptCorrector.correct("my car is fast",
                                                 dictionary: ["Cat"], config: defaults)
        #expect(result.text == "my car is fast")
        #expect(result.corrections.isEmpty)
    }

    @Test func windowMatchingAnotherEntryIsNotFuzzyReplaced() {
        // "presto" is within one edit of "Preston" but is itself the exact
        // spelling of a different entry — it must never become "Preston".
        let result = TranscriptCorrector.correct("presto",
                                                 dictionary: ["Preston", "Presto"], config: defaults)
        #expect(result.text == "Presto")
        #expect(!result.text.contains("Preston"))
        #expect(result.corrections == [.init(original: "presto", replacement: "Presto")])
    }

    @Test func emptyDictionaryIsANoOp() {
        let result = TranscriptCorrector.correct("hello world", dictionary: [])
        #expect(result.text == "hello world")
        #expect(result.corrections.isEmpty)
    }

    @Test func emptyTextIsANoOp() {
        let result = TranscriptCorrector.correct("", dictionary: ["WhisperKit"])
        #expect(result.text.isEmpty)
        #expect(result.corrections.isEmpty)
    }

    // MARK: - Reporting

    @Test func correctionsListReportsOriginalAndReplacement() {
        let result = TranscriptCorrector.correct("using whisper kit and whisperkit",
                                                 dictionary: ["WhisperKit"])
        #expect(result.text == "using WhisperKit and WhisperKit")
        #expect(result.corrections == [
            .init(original: "whisper kit", replacement: "WhisperKit"),
            .init(original: "whisperkit", replacement: "WhisperKit"),
        ])
    }
}
