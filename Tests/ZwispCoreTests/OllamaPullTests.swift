import Testing
@testable import ZwispCore

struct OllamaPullTests {
    // MARK: - OllamaPullEvent.parse()

    @Test func parsesPullingLineWithDigestAndBytes() {
        let event = OllamaPullEvent.parse(
            line: #"{"status":"pulling abc123","digest":"sha256:abc123","total":1000,"completed":250}"#)
        #expect(event == OllamaPullEvent(
            status: "pulling abc123", digest: "sha256:abc123", total: 1000, completed: 250))
    }

    @Test func parsesErrorLine() {
        let event = OllamaPullEvent.parse(line: #"{"error":"model not found"}"#)
        #expect(event?.error == "model not found")
    }

    @Test func parsesBareStatusLine() {
        let event = OllamaPullEvent.parse(line: #"{"status":"pulling manifest"}"#)
        #expect(event == OllamaPullEvent(status: "pulling manifest"))
    }

    @Test func nonJSONAndBlankLinesParseToNil() {
        #expect(OllamaPullEvent.parse(line: "") == nil)
        #expect(OllamaPullEvent.parse(line: "   \n ") == nil)
        #expect(OllamaPullEvent.parse(line: "not json at all") == nil)
        // A bare JSON array isn't an object → skip, don't fail the pull.
        #expect(OllamaPullEvent.parse(line: "[1,2,3]") == nil)
    }

    // MARK: - OllamaPullProgress.apply()

    @Test func progressAccumulatesAcrossLayersMonotonically() {
        var progress = OllamaPullProgress()

        // Layer A: half of 1000.
        let a = progress.apply(OllamaPullEvent(
            status: "pulling a", digest: "a", total: 1000, completed: 500))
        #expect(a == .progress(stage: "pulling a", fraction: 0.5))

        // Layer B announced: 0 of 1000. Overall = 500/2000 = 0.25 raw, but the
        // fraction must not slide backwards from 0.5.
        let b0 = progress.apply(OllamaPullEvent(
            status: "pulling b", digest: "b", total: 1000, completed: 0))
        #expect(b0 == .progress(stage: "pulling b", fraction: 0.5))

        // Layer B fills up: 1500/2000 = 0.75.
        let b1 = progress.apply(OllamaPullEvent(
            status: "pulling b", digest: "b", total: 1000, completed: 1000))
        #expect(b1 == .progress(stage: "pulling b", fraction: 0.75))
    }

    @Test func noTotalsYieldsIndeterminateFraction() {
        var progress = OllamaPullProgress()
        let update = progress.apply(OllamaPullEvent(status: "pulling manifest"))
        #expect(update == .progress(stage: "pulling manifest", fraction: nil))
    }

    @Test func repeatedSameDigestUpdatesInsteadOfDoubleCounting() {
        var progress = OllamaPullProgress()

        _ = progress.apply(OllamaPullEvent(digest: "a", total: 1000, completed: 200))
        // Same layer reports more — replaces, doesn't add a phantom second layer.
        let update = progress.apply(OllamaPullEvent(status: "pulling a", digest: "a", total: 1000, completed: 800))
        #expect(update == .progress(stage: "pulling a", fraction: 0.8))
    }

    @Test func successEndsThePull() {
        var progress = OllamaPullProgress()
        let update = progress.apply(OllamaPullEvent(status: "success"))
        #expect(update == .success)
    }

    @Test func errorFailsThePull() {
        var progress = OllamaPullProgress()
        let update = progress.apply(OllamaPullEvent(error: "boom"))
        #expect(update == .failure("boom"))
    }
}
