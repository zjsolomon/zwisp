import Foundation
import ZwispCore

/// Runs eager transcription passes over the growing recording buffer while the
/// hotkey is held, so that by release most of the audio is already confirmed
/// and the final pass only covers the tail (`StreamingTranscript` decides what
/// confirms). Strictly advisory: any error abandons the session and the
/// dictation falls back to the batch path — reliability cannot regress.
final class StreamingWorker {
    private let recorder: AudioRecorder
    private let transcriber: Transcriber
    private let sampleRate: Double
    private let config: Configuration.Streaming
    private var task: Task<StreamingTranscript?, Never>?

    init(recorder: AudioRecorder, transcriber: Transcriber,
         sampleRate: Double, config: Configuration.Streaming) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.sampleRate = sampleRate
        self.config = config
    }

    func start() {
        guard task == nil else { return }
        let (recorder, transcriber, sampleRate, config) =
            (self.recorder, self.transcriber, self.sampleRate, self.config)
        task = Task {
            var transcript = StreamingTranscript(
                confirmationMarginSeconds: config.confirmationMarginSeconds)
            var lastPassBufferSeconds = 0.0
            var passes = 0
            var lastPassSegments = 0
            while !Task.isCancelled {
                guard (try? await Task.sleep(
                    nanoseconds: UInt64(config.pollInterval * 1_000_000_000))) != nil else {
                    break   // cancelled while idle → hand back what's confirmed
                }
                let samples = recorder.snapshot()
                let bufferSeconds = Double(samples.count) / sampleRate
                guard StreamingTranscript.shouldRunPass(
                    bufferSeconds: bufferSeconds,
                    lastPassBufferSeconds: lastPassBufferSeconds,
                    minNewAudioSeconds: config.minNewAudioSeconds
                ) else { continue }
                do {
                    // A pass that outlives cancellation still ingests: it only
                    // advances the confirmed prefix, which the final tail pass
                    // then starts after — never a conflict.
                    let segments = try await transcriber.segments(
                        for: samples, fromSeconds: transcript.clipStartSeconds)
                    transcript.ingest(segments, bufferSeconds: bufferSeconds)
                    lastPassBufferSeconds = bufferSeconds
                    passes += 1
                    lastPassSegments = segments.count
                } catch {
                    Log.write("streaming pass failed (\(error)); falling back to batch")
                    return nil
                }
            }
            if passes > 0 {
                Log.write("streaming: \(passes) eager pass(es), last pass "
                    + "\(lastPassSegments) segment(s), confirmed up to "
                    + "\(String(format: "%.1f", transcript.clipStartSeconds))s")
            }
            return transcript
        }
    }

    /// Stops the loop (waiting out any in-flight pass) and returns the session,
    /// or `nil` if streaming failed and the caller should use the batch path.
    func finish() async -> StreamingTranscript? {
        guard let task else { return nil }
        task.cancel()
        let transcript = await task.value
        self.task = nil
        return transcript
    }

    /// Fire-and-forget stop, for discarded recordings (stray taps).
    func cancel() {
        task?.cancel()
        task = nil
    }
}
