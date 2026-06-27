import Testing
@testable import ZwhisperCore

struct TextInjectorTests {
    private func string(_ chunk: [UInt16]) -> String {
        String(utf16CodeUnits: chunk, count: chunk.count)
    }

    @Test func splitsAtChunkBoundary() {
        #expect(TextInjector.chunks(of: "abcdef", size: 2).map(string) == ["ab", "cd", "ef"])
    }

    @Test func handlesTrailingRemainder() {
        #expect(TextInjector.chunks(of: "abcde", size: 2).map(string) == ["ab", "cd", "e"])
    }

    @Test func emptyStringYieldsNoChunks() {
        #expect(TextInjector.chunks(of: "", size: 16).isEmpty)
    }

    @Test func chunkSizeLargerThanTextYieldsSingleChunk() {
        #expect(TextInjector.chunks(of: "hi", size: 16).map(string) == ["hi"])
    }

    @Test func multiCodeUnitCharactersRoundTrip() {
        // "😀" is two UTF-16 code units; splitting across chunk boundaries must
        // still reassemble to the exact original text.
        let text = "a😀b😀c"
        let reassembled = TextInjector.chunks(of: text, size: 3).flatMap { $0 }
        #expect(string(reassembled) == text)
    }
}
