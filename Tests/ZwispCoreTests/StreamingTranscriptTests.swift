import Testing
@testable import ZwispCore

struct StreamingTranscriptTests {
    private func seg(_ text: String, _ start: Double, _ end: Double) -> StreamingTranscript.Segment {
        StreamingTranscript.Segment(text: text, start: start, end: end)
    }

    // MARK: - ingest() confirmation rule

    @Test func ingestConfirmsSegmentsClearOfTheLiveEdge() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([
            seg("Hello there.", 0, 3),
            seg("How are you?", 3, 6),
            seg("I was thinking", 6, 9.5),   // ends within 2s of the edge
        ], bufferSeconds: 10)
        #expect(transcript.confirmedTexts == ["Hello there.", "How are you?"])
        #expect(transcript.clipStartSeconds == 6)
    }

    @Test func ingestNeverConfirmsTheTrailingSegment() {
        // A single long segment is typical for continuous speech: even when it
        // ends before the margin cutoff, Whisper may still extend it.
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([seg("One long uninterrupted sentence", 0, 6)], bufferSeconds: 10)
        #expect(transcript.confirmedTexts.isEmpty)
        #expect(!transcript.hasConfirmedAudio)
    }

    @Test func ingestConfirmsNothingWhenAllSegmentsHugTheEdge() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([seg("brand", 8.5, 9.0), seg("new", 9.0, 9.8)], bufferSeconds: 10)
        #expect(transcript.confirmedTexts.isEmpty)
        #expect(transcript.clipStartSeconds == 0)
    }

    @Test func ingestStopsAtTheFirstUnstableSegment() {
        // Confirmation is a prefix: a stable segment after an unstable one
        // must not confirm out of order.
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([
            seg("Early.", 0, 2),
            seg("Late", 7, 9.5),        // inside the margin — blocks the prefix
            seg("Impossible.", 1, 2),   // stable-looking, but after the block
            seg("tail", 9.5, 10),
        ], bufferSeconds: 10)
        #expect(transcript.confirmedTexts == ["Early."])
        #expect(transcript.clipStartSeconds == 2)
    }

    @Test func clipBoundaryOnlyAdvances() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([seg("First part.", 0, 5), seg("tail", 5, 6)], bufferSeconds: 8)
        #expect(transcript.clipStartSeconds == 5)
        // A pathological pass whose stable audio ends before the current
        // boundary must not rewind or duplicate.
        transcript.ingest([seg("stale", 3, 4), seg("tail", 4, 5)], bufferSeconds: 8)
        #expect(transcript.confirmedTexts == ["First part."])
        #expect(transcript.clipStartSeconds == 5)
    }

    @Test func successivePassesAccumulateInOrder() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([seg("One.", 0, 2), seg("Two", 2, 4)], bufferSeconds: 5)
        transcript.ingest([seg("Two.", 2, 4), seg("Three", 4, 7)], bufferSeconds: 8)
        #expect(transcript.confirmedTexts == ["One.", "Two."])
        #expect(transcript.clipStartSeconds == 4)
        #expect(transcript.hasConfirmedAudio)
    }

    // MARK: - finalText()

    @Test func finalTextJoinsConfirmedAndFinalPass() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 2.0)
        transcript.ingest([seg("We should ship it", 0, 3), seg("on", 3, 6)], bufferSeconds: 6)
        #expect(transcript.clipStartSeconds == 3)
        let text = transcript.finalText(finalPassSegments: [seg("on Friday.", 3, 7)])
        #expect(text == "We should ship it on Friday.")
    }

    @Test func finalTextWithNoConfirmedAudioIsJustTheFinalPass() {
        let transcript = StreamingTranscript()
        #expect(transcript.finalText(finalPassSegments: [seg(" Hi there. ", 0, 1)]) == "Hi there.")
    }

    @Test func finalTextSkipsEmptySegments() {
        var transcript = StreamingTranscript(confirmationMarginSeconds: 1.0)
        // The token-only segment confirms but cleans to "", so it must not
        // leave a stray gap in the joined text.
        transcript.ingest([seg("Hello.", 0, 2), seg("<|nospeech|>", 2, 3), seg("x", 3, 5)],
                          bufferSeconds: 5)
        #expect(transcript.confirmedTexts == ["Hello."])
        #expect(transcript.finalText(finalPassSegments: [seg("  ", 3, 5)]) == "Hello.")
    }

    // MARK: - cleanSegmentText()

    @Test func cleanSegmentTextStripsSpecialTokenMarkers() {
        #expect(StreamingTranscript.cleanSegmentText("<|0.00|> Hello world.<|2.40|>")
                == "Hello world.")
        #expect(StreamingTranscript.cleanSegmentText("<|startoftranscript|><|en|>Hi") == "Hi")
        #expect(StreamingTranscript.cleanSegmentText("plain text") == "plain text")
        #expect(StreamingTranscript.cleanSegmentText("<|endoftext|>") == "")
    }

    // MARK: - shouldRunPass()

    @Test func shouldRunPassGatesOnNewAudio() {
        #expect(StreamingTranscript.shouldRunPass(
            bufferSeconds: 2.0, lastPassBufferSeconds: 0.9, minNewAudioSeconds: 1.0))
        #expect(!StreamingTranscript.shouldRunPass(
            bufferSeconds: 1.8, lastPassBufferSeconds: 0.9, minNewAudioSeconds: 1.0))
    }
}

struct AudioPaddingTests {
    @Test func padExtendsShortAudioWithTrailingSilence() {
        let padded = AudioPadding.pad([0.5, -0.5], toAtLeast: 5)
        #expect(padded == [0.5, -0.5, 0, 0, 0])
    }

    @Test func padLeavesLongEnoughAudioUntouched() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        #expect(AudioPadding.pad(samples, toAtLeast: 3) == samples)
        #expect(AudioPadding.pad(samples, toAtLeast: 2) == samples)
    }
}
