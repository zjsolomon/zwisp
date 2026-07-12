import Testing
import Foundation
@testable import ZwispCore

struct CleanupServiceTests {
    /// A fake engine that returns a canned generation (or throws) and records
    /// every request, so prompts and budgets are asserted without a server.
    private final class FakeEngine: CleanupEngine, @unchecked Sendable {
        struct Request {
            let system: String
            let prompt: String
            let maxTokens: Int
            let timeout: TimeInterval
        }

        var result: Result<CleanupGeneration, Error>
        var ready: Bool
        private let lock = NSLock()
        private var _requests: [Request] = []
        var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

        init(result: Result<CleanupGeneration, Error>, ready: Bool = true) {
            self.result = result
            self.ready = ready
        }

        func generate(system: String, prompt: String, maxTokens: Int,
                      timeout: TimeInterval) async throws -> CleanupGeneration {
            lock.lock()
            _requests.append(Request(system: system, prompt: prompt,
                                     maxTokens: maxTokens, timeout: timeout))
            lock.unlock()
            return try result.get()
        }

        func isReady() async -> Bool { ready }
    }

    private func generation(_ text: String,
                            timings: CleanupGeneration.Timings? = nil) -> CleanupGeneration {
        CleanupGeneration(text: text, timings: timings)
    }

    /// Timings whose generation rate is `tokensPerSecond` over `tokens` tokens.
    private func timings(tokens: Int, tokensPerSecond: Double) -> CleanupGeneration.Timings {
        CleanupGeneration.Timings(prefillTokens: 100, prefillSeconds: 0.1,
                                  generatedTokens: tokens,
                                  generatedSeconds: Double(tokens) / tokensPerSecond)
    }

    /// Builds a service backed by an isolated UserDefaults suite so tests never
    /// touch (or depend on) real preferences.
    private func makeService(_ engine: CleanupEngine, enabled: Bool = true,
                             log: @escaping (String) -> Void = { _ in }) -> CleanupService {
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        // No-op log by default: tests must not append to the real ~/Library/Logs file.
        let service = CleanupService(config: Configuration.Cleanup(), engine: engine,
                                     defaults: defaults, log: log)
        service.enabled = enabled
        return service
    }

    // MARK: - clean()

    @Test func cleanReturnsCleanedTextOnSuccess() async {
        let service = makeService(FakeEngine(result: .success(generation("Cleaned."))))
        #expect(await service.clean("raw dictation") == "Cleaned.")
    }

    @Test func cleanFallsBackToRawWhenEngineUnavailable() async {
        let service = makeService(FakeEngine(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanFallsBackToRawOnEmptyOutput() async {
        let service = makeService(FakeEngine(result: .success(generation("  \n "))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanSkipsEngineWhenDisabled() async {
        // The engine would return "Cleaned." if invoked; disabled must not call it.
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine, enabled: false)
        #expect(await service.clean("raw dictation") == "raw dictation")
        #expect(engine.requests.isEmpty)
    }

    @Test func cleanSkipsEmptyInput() async {
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine)
        #expect(await service.clean("") == "")
        #expect(engine.requests.isEmpty)
    }

    @Test func cleanFallsBackToRawWhenOutputFailsSanityChecks() async {
        // A truncated <think> block means the whole output is chain-of-thought.
        let service = makeService(FakeEngine(result: .success(
            generation("<think>The user wants me to"))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanSendsWrappedPromptRenderedSystemAndBudget() async {
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine)
        service.dictionaryProvider = { ["Ziedo", "WhisperKit"] }

        _ = await service.clean("hello there")

        let request = engine.requests[0]
        // The transcript is wrapped in a delimited instruction, so it's embedded
        // rather than sent verbatim.
        #expect(request.prompt.contains("hello there"))
        #expect(request.prompt.contains("<<<"))
        // The system prompt carries the personal dictionary, after the intact base.
        #expect(request.system.contains("PERSONAL DICTIONARY"))
        #expect(request.system.contains("Ziedo, WhisperKit"))
        #expect(request.system.hasPrefix(Configuration.Cleanup.defaultSystemPrompt))
        // Budget: 11 chars × 2, floored at the 100-token minimum.
        #expect(request.maxTokens == 100)
        #expect(request.timeout == Configuration.Cleanup().timeout)
    }

    @Test func cleanLeavesSystemPromptAloneWhenDictionaryIsEmpty() async {
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine)

        _ = await service.clean("hello")
        #expect(engine.requests[0].system == Configuration.Cleanup.defaultSystemPrompt)
    }

    // MARK: - status()

    @Test func statusIsOffWhenDisabledWithoutTouchingTheEngine() async {
        let service = makeService(FakeEngine(result: .success(generation("x")), ready: true),
                                  enabled: false)
        #expect(await service.status() == .off)
    }

    @Test func statusIsActiveWithTheBundledModelNameWhenEngineIsReady() async {
        let service = makeService(FakeEngine(result: .success(generation("x")), ready: true))
        #expect(await service.status() == .active(model: Configuration.Cleanup().modelFile.displayName))
    }

    @Test func statusIsUnavailableWhenEngineIsDown() async {
        let service = makeService(FakeEngine(result: .success(generation("x")), ready: false))
        #expect(await service.status() == .unavailable)
    }

    // MARK: - warmUp()

    @Test func warmUpGeneratesOneTokenThroughTheSharedPromptShape() async {
        let engine = FakeEngine(result: .success(generation("R")))
        let service = makeService(engine)
        service.dictionaryProvider = { ["Ziedo"] }

        #expect(await service.warmUp() == true)

        let warm = engine.requests[0]
        // Side effects only — generate as little as possible.
        #expect(warm.maxTokens == 1)
        // Cold loads can exceed the dictation timeout; the warm-up gets its own.
        #expect(warm.timeout == Configuration.Cleanup().warmupTimeout)
        // The cache-sharing contract: warm-up must render the exact system
        // prompt and instruction prefix real requests use, or the prefill is
        // wasted and every dictation pays it again.
        _ = await service.clean("hello")
        let real = engine.requests[1]
        #expect(warm.system == real.system)
        let sharedPrefix = CleanupService.wrapPrompt("x").components(separatedBy: "<<<")[0]
        #expect(warm.prompt.hasPrefix(sharedPrefix))
        #expect(real.prompt.hasPrefix(sharedPrefix))
    }

    @Test func warmUpSkipsEngineWhenDisabled() async {
        let engine = FakeEngine(result: .success(generation("R")))
        let service = makeService(engine, enabled: false)
        #expect(await service.warmUp() == false)
        #expect(engine.requests.isEmpty)
    }

    @Test func warmUpReportsFailureWhenEngineIsDown() async {
        let service = makeService(FakeEngine(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await service.warmUp() == false)
    }

    @Test func warmupAndCleanShareTheSameSystemPromptForAStyle() async {
        let engine = FakeEngine(result: .success(generation("R")))
        let service = makeService(engine)
        service.dictionaryProvider = { ["Ziedo"] }

        _ = await service.warmUp(style: .formal)
        _ = await service.clean("hello", style: .formal)
        #expect(engine.requests[0].system == engine.requests[1].system)
    }

    // MARK: - writing styles

    @Test func casualCleanCarriesCasualBlockAndDropsPunctuateOpener() async {
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine)

        _ = await service.clean("hey whats up", style: .casual)

        let request = engine.requests[0]
        #expect(request.system.contains("CASUAL CHAT"))
        // The casual opener replaces "Punctuate and case", which would fight the
        // lowercase counter-examples.
        #expect(!request.prompt.contains("Punctuate and case"))
        #expect(request.prompt.contains("casual chat style"))
    }

    @Test func standardStyleCleanIsByteIdenticalToNoStyleCall() async {
        let engine = FakeEngine(result: .success(generation("Cleaned.")))
        let service = makeService(engine)
        service.dictionaryProvider = { ["Ziedo"] }

        _ = await service.clean("hello there")
        _ = await service.clean("hello there", style: .standard)
        #expect(engine.requests[0].system == engine.requests[1].system)
        #expect(engine.requests[0].prompt == engine.requests[1].prompt)
    }

    // MARK: - predictive skip

    @Test func throughputSampleComputesTokensPerSecond() {
        let sample = CleanupService.throughputSample(timings: timings(tokens: 24, tokensPerSecond: 77.4))
        #expect(abs((sample ?? 0) - 77.4) < 0.001)
    }

    @Test func throughputSampleIgnoresTinyGenerations() {
        // A warm-up (1 token) or near-empty edit is too small to trust.
        #expect(CleanupService.throughputSample(timings: timings(tokens: 1, tokensPerSecond: 200)) == nil)
        #expect(CleanupService.throughputSample(timings: timings(tokens: 7, tokensPerSecond: 200)) == nil)
    }

    @Test func throughputSampleIsNilForDegenerateTimings() {
        let zeroDuration = CleanupGeneration.Timings(
            prefillTokens: 0, prefillSeconds: 0, generatedTokens: 50, generatedSeconds: 0)
        #expect(CleanupService.throughputSample(timings: zeroDuration) == nil)
    }

    @Test func updatedThroughputSeedsThenBlends() {
        // First sample seeds the average outright.
        #expect(CleanupService.updatedThroughput(previous: nil, sample: 20) == 20)
        // Later samples blend at alpha (0.3): 0.3*40 + 0.7*20 = 26.
        #expect(CleanupService.updatedThroughput(previous: 20, sample: 40, alpha: 0.3) == 26)
    }

    @Test func estimatedOutputTokensIsInputLengthOverFour() {
        #expect(CleanupService.estimatedOutputTokens(characterCount: 400) == 100)
        #expect(CleanupService.estimatedOutputTokens(characterCount: 3) == 1)  // floor
    }

    @Test func predictedWaitDividesTokensByThroughput() {
        // 400 chars → ~100 tokens; at 20 tok/s that's ~5s.
        #expect(abs(CleanupService.predictedWait(characterCount: 400, throughput: 20) - 5) < 0.001)
    }

    @Test func cleanSkipsWhenPredictedWaitExceedsCapAndLogs() async {
        var logged: [String] = []
        // 16 tok/s: a slow engine whose first clean seeds the EWMA.
        let engine = FakeEngine(result: .success(
            generation("Cleaned.", timings: timings(tokens: 16, tokensPerSecond: 16))))
        let service = makeService(engine, log: { logged.append($0) })

        // First call measures throughput (~16 tok/s) and returns cleaned text.
        let short = String(repeating: "a", count: 40)   // ~10 tokens → ~0.6s, under cap
        #expect(await service.clean(short) == "Cleaned.")

        // A long input now predicts well past the cap and is skipped up front.
        let long = String(repeating: "a", count: 4_000)  // ~1000 tokens → ~62s
        #expect(await service.clean(long) == long)
        #expect(engine.requests.count == 1)   // the skip never reached the engine
        #expect(logged.contains { $0.contains("cleanup skipped (predicted") && $0.contains("using raw text") })
    }

    @Test func cleanNeverSkipsWithoutAPriorObservation() async {
        // Fresh install: no measured throughput, so even a huge input is tried.
        let service = makeService(FakeEngine(result: .success(generation("Cleaned."))))
        let long = String(repeating: "a", count: 10_000)
        #expect(await service.clean(long) == "Cleaned.")
    }

    @Test func cleanDoesNotSkipWhenPredictionIsUnderCap() async {
        // 200 tok/s: a fast engine whose predictions pass, so cleanup runs.
        let engine = FakeEngine(result: .success(
            generation("Cleaned.", timings: timings(tokens: 200, tokensPerSecond: 200))))
        let service = makeService(engine)

        #expect(await service.clean("first call measures throughput") == "Cleaned.")
        // Even a long input predicts under 4s at 200 tok/s, so cleanup runs.
        let long = String(repeating: "a", count: 2_000)  // ~500 tokens → 2.5s
        #expect(await service.clean(long) == "Cleaned.")
        #expect(engine.requests.count == 2)
    }

    @Test func observedThroughputPersistsAcrossInstancesSharingDefaults() async {
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        // 16 tok/s slow engine.
        let slow = FakeEngine(result: .success(
            generation("Cleaned.", timings: timings(tokens: 16, tokensPerSecond: 16))))
        let first = CleanupService(config: Configuration.Cleanup(), engine: slow,
                                   defaults: defaults, log: { _ in })
        // Measure and persist the throughput.
        _ = await first.clean("a call long enough to be a meaningful sample")

        // A fresh service over the same defaults inherits the measurement and
        // skips a long input immediately — proving the throughput persisted.
        var logged: [String] = []
        let untouched = FakeEngine(result: .success(generation("Cleaned.")))
        let second = CleanupService(config: Configuration.Cleanup(), engine: untouched,
                                    defaults: defaults, log: { logged.append($0) })
        let long = String(repeating: "a", count: 4_000)
        #expect(await second.clean(long) == long)
        #expect(untouched.requests.isEmpty)
        #expect(logged.contains { $0.contains("cleanup skipped") })
    }

    @Test func warmUpDoesNotSeedTheThroughputEWMA() async {
        // A warm-up generates 1 token; its "throughput" must not seed the EWMA,
        // or a later long input would be skipped on a bogus measurement.
        let engine = FakeEngine(result: .success(
            generation("R", timings: timings(tokens: 1, tokensPerSecond: 1))))
        let service = makeService(engine)
        #expect(await service.warmUp() == true)

        engine.result = .success(generation("Cleaned."))
        let long = String(repeating: "a", count: 8_000)
        #expect(await service.clean(long) == "Cleaned.")
    }

    @Test func responseTokenBudgetScalesWithInputAndClamps() {
        let config = Configuration.Cleanup(
            minResponseTokens: 100, maxResponseTokens: 2_048, responseTokenMultiplier: 2)
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        let service = CleanupService(
            config: config, engine: FakeEngine(result: .failure(URLError(.badURL))),
            defaults: defaults, log: { _ in })

        #expect(service.responseTokenBudget(for: "short") == 100)                        // floor
        #expect(service.responseTokenBudget(for: String(repeating: "a", count: 300)) == 600)
        #expect(service.responseTokenBudget(for: String(repeating: "a", count: 5_000)) == 2_048) // cap
    }

    // MARK: - CleanupGeneration.Timings

    @Test func timingsLogSummaryRendersProseAndDraftStats() {
        let withDraft = CleanupGeneration.Timings(
            prefillTokens: 176, prefillSeconds: 1.72,
            generatedTokens: 173, generatedSeconds: 4.65,
            draftTokens: 216, draftAccepted: 134)
        #expect(withDraft.logSummary
                == "prefill 176tk 1.72s, generate 173tk 4.65s, draft 134/216 (62%)")

        let noDraft = CleanupGeneration.Timings(
            prefillTokens: 996, prefillSeconds: 0.45,
            generatedTokens: 1, generatedSeconds: 0)
        #expect(noDraft.logSummary == "prefill 996tk 0.45s, generate 1tk 0.00s")
    }

    // MARK: - sanitize()

    @Test func sanitizePassesOrdinaryOutputThrough() {
        #expect(CleanupService.sanitize("Hello world.", raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeStripsThinkBlocks() {
        let output = "<think>\nThe user said hello world.\n</think>\n\nHello world."
        #expect(CleanupService.sanitize(output, raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeRejectsUnclosedThinkBlock() {
        // Token budget cut generation off mid-think: nothing usable.
        #expect(CleanupService.sanitize("<think>The user wants", raw: "hello world") == nil)
    }

    @Test func sanitizeStripsEndTokens() {
        #expect(CleanupService.sanitize("Hello world.<|im_end|>", raw: "hello world") == "Hello world.")
        #expect(CleanupService.sanitize("Hello world.</s>", raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeRejectsRunawayGeneration() {
        // Output far longer than the dictation = the model answered, not cleaned.
        let essay = String(repeating: "The sea is vast and blue. ", count: 30)
        #expect(CleanupService.sanitize(essay, raw: "write me a poem about the sea") == nil)
    }

    @Test func sanitizeAllowsModestGrowth() {
        // Punctuation and casing legitimately grow the text a little.
        let raw = "hi"
        #expect(CleanupService.sanitize("Hi there!", raw: raw) == "Hi there!")
    }

    @Test func sanitizeStripsEchoedWrapDelimiters() {
        let output = "<<<\nHello world.\n>>>"
        #expect(CleanupService.sanitize(output, raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeDropsPreambleLabelLine() {
        let output = "Here is the cleaned text:\nHello world."
        #expect(CleanupService.sanitize(output, raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeKeepsLabelLikeLineDictatedByUser() {
        let output = "Here is the cleaned version:\nStep one."
        let raw = "here is the cleaned version colon step one"
        #expect(CleanupService.sanitize(output, raw: raw) == output)
    }

    // MARK: - conservation guardrail

    @Test func sanitizeRejectsParaphraseThatDropsSpokenWords() {
        // "Okay, let's see here" is the speaker's voice, not filler. An output
        // that trims it is a paraphrase and must lose to the raw transcript.
        let raw = "okay lets see here so what im thinking is we take the simple approach"
        let paraphrased = "I'm thinking we take the simple approach."
        #expect(CleanupService.sanitize(paraphrased, raw: raw) == nil)
    }

    @Test func sanitizeAcceptsFaithfulEditOfFreeformSpeech() {
        let raw = "okay lets see here um so what im thinking is we take the simple approach"
        let faithful = "Okay, let's see here. So what I'm thinking is we take the simple approach."
        #expect(CleanupService.sanitize(faithful, raw: raw) == faithful)
    }

    @Test func sanitizeAcceptsSelfCorrectionRemovals() {
        // Correction markers and revoked number words are ignorable, so a
        // legitimate correction doesn't trip the conservation check.
        let raw = "we need three no wait four copies by friday for the offsite"
        #expect(CleanupService.sanitize("We need four copies by Friday for the offsite.", raw: raw)
                == "We need four copies by Friday for the offsite.")
    }

    @Test func sanitizeAcceptsSpokenPunctuationAndNumberConversion() {
        // "five thirty pm" → "5:30 PM" and "comma" → "," lose only ignorable words.
        let raw = "the meeting moved to five thirty pm comma so update the invite"
        let converted = "The meeting moved to 5:30 PM, so update the invite."
        #expect(CleanupService.sanitize(converted, raw: raw) == converted)
    }

    @Test func retainedWordFractionIsFullForShortDictations() {
        // Too few content words to judge — never reject on tiny inputs.
        #expect(CleanupService.retainedWordFraction(raw: "hello world", cleaned: "Hi.") == 1.0)
    }

    @Test func retainedWordFractionIgnoresCaseAndPunctuation() {
        let fraction = CleanupService.retainedWordFraction(
            raw: "lets ship the zwisp build on friday",
            cleaned: "Let's ship the zwisp build on Friday!")
        #expect(fraction == 1.0)
    }

    @Test func sanitizeUnwrapsQuotesTheModelAdded() {
        #expect(CleanupService.sanitize("\"Hello world.\"", raw: "hello world") == "Hello world.")
        #expect(CleanupService.sanitize("“Hello world.”", raw: "hello world") == "Hello world.")
    }

    @Test func sanitizeKeepsQuotesTheSpeakerDictated() {
        let raw = "\"quote hello world end quote\""
        #expect(CleanupService.sanitize("\"Hello world.\"", raw: raw) == "\"Hello world.\"")
    }

    // MARK: - sanitize is style-safe

    @Test func sanitizePassesAllLowercaseCasualOutput() {
        // Casual output is all lowercase with no trailing period; the
        // conservation check normalizes case, so retention still holds.
        let raw = "hey can you send me the link to the doc"
        let casual = "hey can you send me the link to the doc"
        #expect(CleanupService.sanitize(casual, raw: raw) == casual)
        #expect(CleanupService.retainedWordFraction(raw: raw, cleaned: casual) >= 0.7)
    }

    @Test func sanitizePassesFormalOutputWithParagraphBreaks() {
        // Formal output introduces \n\n paragraph breaks and a sign-off line;
        // added whitespace can't hurt word retention or bust the length cap.
        let raw = "hi sarah just wanted to follow up on the contract could you send the signed copy by friday thanks ziedo"
        let formal = "Hi Sarah,\n\nJust wanted to follow up on the contract. Could you send the signed copy by Friday?\n\nThanks,\nZiedo"
        #expect(CleanupService.sanitize(formal, raw: raw) == formal)
    }

    // MARK: - wrapPrompt()

    @Test func wrapPromptEmbedsTheTextBetweenDelimiters() {
        let wrapped = CleanupService.wrapPrompt("what's the capital of france")
        #expect(wrapped.contains("what's the capital of france"))
        #expect(wrapped.contains("<<<"))
        #expect(wrapped.contains(">>>"))
        // It instructs the model to clean rather than answer.
        #expect(wrapped.lowercased().contains("do not answer"))
    }
}
