import Foundation
import WhisperKit
import ZwispCore

/// Thin wrapper around WhisperKit. The model is downloaded from Hugging Face on
/// first use (needs internet once), then cached locally and runs fully offline.
///
/// An actor whose calls are additionally chained through `tail`: WhisperKit
/// must never run two transcriptions concurrently, and with streaming the
/// eager passes of a new dictation can overlap the final pass of the previous
/// one still in the pipeline. Every caller shares this one queue.
actor Transcriber {
    private let whisperKit: WhisperKit
    /// Recordings are padded with trailing silence to this length: WhisperKit
    /// decodes nothing for clips under its 1 s `windowClipTime`, silently
    /// turning a quick dictation into an empty transcript.
    private let minimumSamples: Int
    private var tail: Task<Void, Never>?

    /// Loads WhisperKit from an already-downloaded model folder. The download is
    /// no longer this type's job — `SpeechModelInstaller` fetches the model
    /// (with visible progress) and hands us the folder — so we point
    /// `WhisperKitConfig` at it directly and skip the network entirely.
    ///
    /// `prewarm: true` pays CoreML/ANE specialization at load time (the menu bar
    /// already shows "loading") instead of on the first dictation. With
    /// `modelFolder` set, `load` defaults to true, so this initializer both
    /// loads and warms the model in one shot.
    init(modelFolder: URL, minimumTranscribableSamples: Int) async throws {
        let config = WhisperKitConfig(modelFolder: modelFolder.path, prewarm: true)
        whisperKit = try await WhisperKit(config)
        minimumSamples = minimumTranscribableSamples
    }

    /// Batch transcription of a complete recording (the non-streaming path).
    func transcribe(_ samples: [Float]) async -> String {
        guard !samples.isEmpty else { return "" }
        do {
            let padded = AudioPadding.pad(samples, toAtLeast: minimumSamples)
            let results = try await run(samples: padded, options: nil)
            return TranscriptFormatter.join(results.map { $0.text })
        } catch {
            NSLog("zwisp: transcription error: \(error)")
            return ""
        }
    }

    /// One eager/final streaming pass: transcribes `samples` starting at
    /// `fromSeconds` (`clipTimestamps` skips already-confirmed audio) and
    /// returns the segments for `StreamingTranscript` to confirm/assemble.
    func segments(for samples: [Float],
                  fromSeconds clipStart: Double) async throws -> [StreamingTranscript.Segment] {
        guard !samples.isEmpty else { return [] }
        var options = DecodingOptions()
        options.clipTimestamps = [Float(clipStart)]
        let results = try await run(samples: AudioPadding.pad(samples, toAtLeast: minimumSamples),
                                    options: options)
        return results.flatMap(\.segments).map {
            StreamingTranscript.Segment(text: $0.text,
                                        start: Double($0.start), end: Double($0.end))
        }
    }

    /// Chains every WhisperKit call behind the previous one, FIFO. The wrapped
    /// unstructured Task also insulates an in-flight pass from the caller's
    /// cancellation — a cancelled eager pass still completes and its result is
    /// simply discarded by the worker.
    private func run(samples: [Float],
                     options: DecodingOptions?) async throws -> [TranscriptionResult] {
        let previous = tail
        let task = Task { () throws -> [TranscriptionResult] in
            await previous?.value
            return try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
