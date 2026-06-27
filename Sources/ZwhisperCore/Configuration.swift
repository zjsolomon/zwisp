import Foundation

/// All tunable knobs in one place, so behaviour can be changed (and tested)
/// without hunting for magic numbers scattered across the source.
public struct Configuration {
    public var whisperModel: String
    public var audio: Audio
    public var cleanup: Cleanup
    public var injection: Injection

    public init(
        whisperModel: String,
        audio: Audio = Audio(),
        cleanup: Cleanup = Cleanup(),
        injection: Injection = Injection()
    ) {
        self.whisperModel = whisperModel
        self.audio = audio
        self.cleanup = cleanup
        self.injection = injection
    }

    /// Microphone capture / WhisperKit input format.
    public struct Audio {
        /// WhisperKit expects 16 kHz mono Float32.
        public var sampleRate: Double
        /// Recordings shorter than this are treated as a stray Fn tap and dropped.
        /// 1 600 samples ≈ 0.1 s at 16 kHz.
        public var minimumSampleCount: Int

        public init(sampleRate: Double = 16_000, minimumSampleCount: Int = 1_600) {
            self.sampleRate = sampleRate
            self.minimumSampleCount = minimumSampleCount
        }
    }

    /// Optional local-LLM cleanup pass (Ollama).
    public struct Cleanup {
        public var endpoint: URL
        /// Any small instruct model pulled in Ollama, e.g. `ollama pull llama3.2:3b`.
        public var model: String
        public var temperature: Double
        public var timeout: TimeInterval
        public var systemPrompt: String

        public init(
            endpoint: URL = URL(string: "http://127.0.0.1:11434/api/generate")!,
            model: String = "llama3.2:3b",
            temperature: Double = 0.2,
            timeout: TimeInterval = 20,
            systemPrompt: String = Cleanup.defaultSystemPrompt
        ) {
            self.endpoint = endpoint
            self.model = model
            self.temperature = temperature
            self.timeout = timeout
            self.systemPrompt = systemPrompt
        }

        public static let defaultSystemPrompt = """
        You clean up raw speech-to-text dictation into polished written text.
        - Fix punctuation, capitalization, and obvious transcription mistakes.
        - Remove filler words (um, uh, like) and false starts / self-corrections, \
        keeping the speaker's intended wording and meaning.
        - Do NOT add new content, do NOT answer questions, do NOT add commentary or quotes.
        Output ONLY the cleaned text, nothing else.
        """
    }

    /// Synthetic-keystroke text injection.
    public struct Injection {
        /// `keyboardSetUnicodeString` is only reliable in small chunks.
        public var chunkSize: Int
        /// Small gap between chunks so fast apps don't drop events.
        public var interKeystrokeDelayMicroseconds: useconds_t

        public init(chunkSize: Int = 16, interKeystrokeDelayMicroseconds: useconds_t = 2_000) {
            self.chunkSize = chunkSize
            self.interKeystrokeDelayMicroseconds = interKeystrokeDelayMicroseconds
        }
    }

    /// The shipped defaults.
    ///
    /// `large-v3-turbo`: near-large-v3 accuracy, fast on Apple Silicon — best for
    /// dictation. Lighter/faster alternatives you can drop in here:
    ///   "distil-whisper_distil-large-v3_turbo"  (smaller, English-leaning)
    ///   "openai_whisper-small.en"               (much smaller, lower accuracy)
    ///   "openai_whisper-base.en"                (tiny, fastest)
    public static let `default` = Configuration(
        whisperModel: "openai_whisper-large-v3-v20240930_turbo"
    )
}
