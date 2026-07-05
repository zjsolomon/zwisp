import Foundation

/// Pure state machine for eager ("streaming") transcription. While the hotkey
/// is held, the app repeatedly transcribes the growing audio buffer; each pass
/// covers only [`clipStartSeconds`, buffer end]. This type decides which of a
/// pass's segments are stable enough to *confirm*: a segment counts as stable
/// once it ended at least `confirmationMarginSeconds` before the live edge of
/// the buffer — Whisper's hypothesis is only unstable near the edge. (Segment
/// count is deliberately not the signal: continuous speech often decodes as a
/// single long segment per pass, which starved a count-based rule.) The
/// trailing segment of a pass never confirms, since Whisper may still extend it.
///
/// Confirmed text and the clip boundary only ever advance, so on key release
/// the final pass transcribes just the unconfirmed tail and the full result is
/// `finalText(finalPassSegments:)`. The state is purely advisory: the raw
/// sample buffer is untouched throughout, and discarding an instance simply
/// falls back to batch transcription.
public struct StreamingTranscript {
    /// One WhisperKit segment, reduced to what confirmation needs. Times are
    /// seconds from the start of the recording (WhisperKit reports them
    /// seek-adjusted, so they stay absolute across clipped passes).
    public struct Segment: Equatable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Cleaned text of every confirmed segment, in spoken order.
    public private(set) var confirmedTexts: [String] = []
    /// Where the next pass should start decoding (`DecodingOptions.clipTimestamps`).
    public private(set) var clipStartSeconds: Double = 0

    private let confirmationMarginSeconds: Double

    public init(confirmationMarginSeconds: Double = 2.0) {
        self.confirmationMarginSeconds = max(0, confirmationMarginSeconds)
    }

    /// True once at least one segment has been confirmed — i.e. streaming has
    /// actually saved work and the final pass can start at `clipStartSeconds`.
    public var hasConfirmedAudio: Bool { clipStartSeconds > 0 }

    /// Feeds the segments of one eager pass (transcribed from
    /// `clipStartSeconds` to the end of the buffer, whose length at snapshot
    /// time is `bufferSeconds`). Confirms the leading run of segments that
    /// ended at least `confirmationMarginSeconds` before the buffer's live
    /// edge — never the trailing segment, which Whisper may still extend —
    /// and advances the clip boundary, only ever forwards.
    public mutating func ingest(_ segments: [Segment], bufferSeconds: Double) {
        let cutoff = bufferSeconds - confirmationMarginSeconds
        let toConfirm = segments.dropLast().prefix { $0.end <= cutoff }
        guard let last = toConfirm.last, last.end > clipStartSeconds else { return }
        confirmedTexts.append(contentsOf: toConfirm.map { Self.cleanSegmentText($0.text) }
            .filter { !$0.isEmpty })
        clipStartSeconds = last.end
    }

    /// The complete transcript: confirmed text plus the segments of the final
    /// (post-release) pass over the unconfirmed tail.
    public func finalText(finalPassSegments: [Segment]) -> String {
        let tail = finalPassSegments.map { Self.cleanSegmentText($0.text) }
            .filter { !$0.isEmpty }
        return TranscriptFormatter.join(confirmedTexts + tail)
    }

    /// Pure gate for the worker loop: run a pass only once enough new audio
    /// has accumulated since the last one (Whisper on a near-unchanged buffer
    /// is wasted compute and returns the same hypothesis).
    public static func shouldRunPass(
        bufferSeconds: Double,
        lastPassBufferSeconds: Double,
        minNewAudioSeconds: Double
    ) -> Bool {
        bufferSeconds - lastPassBufferSeconds >= minNewAudioSeconds
    }

    /// Segment text as WhisperKit reports it can carry special-token markers
    /// (`<|0.00|>`, `<|endoftext|>`, …); strip them and trim, keeping only the
    /// spoken words.
    static func cleanSegmentText(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<|"),
              let close = result.range(of: "|>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
