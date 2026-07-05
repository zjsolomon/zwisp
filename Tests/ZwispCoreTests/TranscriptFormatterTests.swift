import Testing
@testable import ZwispCore

struct TranscriptFormatterTests {
    @Test func joinsSegmentsWithSingleSpaces() {
        #expect(TranscriptFormatter.join(["Hello", "world"]) == "Hello world")
    }

    @Test func trimsSurroundingWhitespaceButKeepsInterior() {
        #expect(TranscriptFormatter.join([" Hello ", " world "]) == "Hello   world")
    }

    @Test func emptyInputYieldsEmptyString() {
        #expect(TranscriptFormatter.join([]) == "")
    }

    @Test func singleSegmentIsTrimmed() {
        #expect(TranscriptFormatter.join(["  hi  "]) == "hi")
    }
}
