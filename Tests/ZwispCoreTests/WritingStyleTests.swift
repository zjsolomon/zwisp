import Foundation
import Testing
@testable import ZwispCore

struct WritingStyleTests {
    // MARK: - promptBlock

    @Test func standardHasNoPromptBlock() {
        // Standard must leave the base prompt untouched (byte-identical below).
        #expect(WritingStyle.standard.promptBlock == nil)
    }

    @Test func formalAndCasualHavePromptBlocks() {
        let formal = try? #require(WritingStyle.formal.promptBlock)
        #expect(formal?.contains("FORMAL") == true)
        let casual = try? #require(WritingStyle.casual.promptBlock)
        #expect(casual?.contains("CASUAL CHAT") == true)
    }

    @Test func formalIsFormatOnly() {
        // The conservation guarantee: formal reshapes layout, never invents words.
        let formal = WritingStyle.formal.promptBlock ?? ""
        #expect(formal.contains("changes layout and punctuation only"))
    }

    @Test func casualCarriesLowercaseCounterExamples() {
        let casual = WritingStyle.casual.promptBlock ?? ""
        #expect(casual.contains("all lowercase"))
        // A lowercase counter-example that overrides the base few-shot output.
        #expect(casual.contains("i'll be there at 5:30"))
    }

    // MARK: - displayName

    @Test func displayNamesAreStable() {
        #expect(WritingStyle.standard.displayName == "Standard")
        #expect(WritingStyle.formal.displayName == "Formal (email)")
        #expect(WritingStyle.casual.displayName == "Casual (chat)")
    }

    // MARK: - Codable round-trip

    @Test func rawValueRoundTrips() {
        for style in WritingStyle.allCases {
            #expect(WritingStyle(rawValue: style.rawValue) == style)
        }
    }

    @Test func unknownRawValueIsNil() {
        #expect(WritingStyle(rawValue: "telepathic") == nil)
    }

    // MARK: - systemPrompt regression

    @Test func standardStyleRendersByteIdenticalToBasePrompt() {
        // The whole point of `.standard`: no behavioural change for existing users.
        let base = Configuration.Cleanup.defaultSystemPrompt
        #expect(Configuration.Cleanup.systemPrompt(base: base, dictionary: [], style: .standard) == base)
        // And the default argument matches the two-arg call site.
        #expect(Configuration.Cleanup.systemPrompt(base: base, dictionary: [])
                == Configuration.Cleanup.systemPrompt(base: base, dictionary: [], style: .standard))
    }

    @Test func styleBlockIsAppendedAfterTheDictionary() {
        // Order must be base < dictionary < style so a style switch only
        // re-prefills the KV suffix.
        let base = Configuration.Cleanup.defaultSystemPrompt
        let rendered = Configuration.Cleanup.systemPrompt(
            base: base, dictionary: ["Zied"], style: .formal)

        let dictRange = try? #require(rendered.range(of: "PERSONAL DICTIONARY"))
        let styleRange = try? #require(rendered.range(of: "WRITING STYLE"))
        #expect(rendered.hasPrefix(base))
        #expect(dictRange != nil && styleRange != nil)
        if let dictRange, let styleRange {
            #expect(dictRange.lowerBound < styleRange.lowerBound)
        }
    }

    @Test func styleBlockAppendsEvenWithEmptyDictionary() {
        let base = Configuration.Cleanup.defaultSystemPrompt
        let rendered = Configuration.Cleanup.systemPrompt(
            base: base, dictionary: [], style: .casual)
        #expect(rendered.hasPrefix(base))
        #expect(rendered.contains("CASUAL CHAT"))
        #expect(!rendered.contains("PERSONAL DICTIONARY"))
        // Separated from the base by exactly one blank line.
        #expect(rendered == base + "\n\n" + (WritingStyle.casual.promptBlock ?? ""))
    }
}
