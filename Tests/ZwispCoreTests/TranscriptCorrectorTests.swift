import Testing
import Foundation
@testable import ZwispCore

struct TranscriptCorrectorTests {
    // Default config: fuzzyMinLength 5, fuzzyTwoEditMinLength 8. Short names
    // (like "Dana") are deliberately fuzzy-ineligible under the defaults.
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
        // "Ziedo" is exactly fuzzyMinLength, so it is eligible under the
        // defaults — but only one edit away, which "zeedo" is.
        let result = TranscriptCorrector.correct("call zeedo", dictionary: ["Ziedo"])
        #expect(result.text == "call Ziedo")
        #expect(result.corrections == [.init(original: "zeedo", replacement: "Ziedo")])
    }

    @Test func twoEditMishearingNeedsALoweredThreshold() {
        // "zeddo" is two edits from "Ziedo", and at 5 letters only one is
        // tolerated by default — exactly the tradeoff the config knob exposes.
        #expect(TranscriptCorrector.correct("call zeddo",
                                            dictionary: ["Ziedo"], config: defaults).text == "call zeddo")

        let config = Configuration.PersonalDictionary(fuzzyTwoEditMinLength: 5)
        let result = TranscriptCorrector.correct("call zeddo", dictionary: ["Ziedo"], config: config)
        #expect(result.text == "call Ziedo")
        #expect(result.corrections == [.init(original: "zeddo", replacement: "Ziedo")])
    }

    @Test func fuzzyMatchFixesMisheardMultiWordName() {
        // Normalized "ziedosolomon" is 12 chars, so 2 edits are tolerated and
        // even "zeddo solomon" is fixed under the *defaults*.
        let result = TranscriptCorrector.correct("email zeddo solomon",
                                                 dictionary: ["Ziedo Solomon"])
        #expect(result.text == "email Ziedo Solomon")
        #expect(result.corrections == [.init(original: "zeddo solomon", replacement: "Ziedo Solomon")])
    }

    // MARK: - Punctuation preservation

    @Test func punctuationSurvivesAroundReplacement() {
        let result = TranscriptCorrector.correct("ask zeedo.", dictionary: ["Ziedo"])
        #expect(result.text == "ask Ziedo.")
        #expect(result.corrections == [.init(original: "zeedo", replacement: "Ziedo")])
    }

    @Test func surroundingBracketsAndQuotesSurvive() {
        let result = TranscriptCorrector.correct("(whisperkit) is \"whisperkit\"",
                                                 dictionary: ["WhisperKit"])
        #expect(result.text == "(WhisperKit) is \"WhisperKit\"")
    }

    // MARK: - Negative / safety

    @Test func shortEntryDoesNotCaptureCommonWords() {
        // Under the defaults "Dana" is fuzzy-ineligible, so nearby everyday
        // words ("data", "dane") are left completely alone.
        let result = TranscriptCorrector.correct("the data came back",
                                                 dictionary: ["Dana"], config: defaults)
        #expect(result.text == "the data came back")
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
