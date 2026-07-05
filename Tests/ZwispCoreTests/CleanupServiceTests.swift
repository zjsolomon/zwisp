import Testing
import Foundation
@testable import ZwispCore

struct CleanupServiceTests {
    /// A fake HTTP client that returns a canned result (or throws) without
    /// touching the network.
    private struct FakeClient: HTTPClient {
        var result: Result<(Data, URLResponse), Error>
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try result.get()
        }
    }

    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Builds a service backed by an isolated UserDefaults suite so tests never
    /// touch (or depend on) real preferences.
    private func makeService(_ client: HTTPClient, enabled: Bool = true) -> CleanupService {
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        // No-op log: tests must not append to the real ~/Library/Logs file.
        let service = CleanupService(config: Configuration.Cleanup(), httpClient: client,
                                     defaults: defaults, log: { _ in })
        service.enabled = enabled
        return service
    }

    private func json(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - parse()

    @Test func parseExtractsAndTrimsResponseField() {
        let data = json(#"{"response":"  Hello world.  "}"#)
        #expect(CleanupService.parse(data: data, response: response(200)) == "Hello world.")
    }

    @Test func parseReturnsNilForNon200() {
        #expect(CleanupService.parse(data: json(#"{"response":"Hi"}"#), response: response(500)) == nil)
    }

    @Test func parseReturnsNilForEmptyResponseField() {
        #expect(CleanupService.parse(data: json(#"{"response":"   "}"#), response: response(200)) == nil)
    }

    @Test func parseReturnsNilForMalformedJSON() {
        #expect(CleanupService.parse(data: json("not json"), response: response(200)) == nil)
    }

    // MARK: - clean()

    @Test func cleanReturnsCleanedTextOnSuccess() async {
        let service = makeService(FakeClient(result: .success((json(#"{"response":"Cleaned."}"#), response(200)))))
        #expect(await service.clean("raw dictation") == "Cleaned.")
    }

    @Test func cleanFallsBackToRawWhenServerUnavailable() async {
        let service = makeService(FakeClient(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanFallsBackToRawOnUnusableResponse() async {
        let service = makeService(FakeClient(result: .success((json("nope"), response(200)))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanSkipsNetworkWhenDisabled() async {
        // The client would throw if invoked; disabled cleanup must not call it.
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))), enabled: false)
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    @Test func cleanSkipsEmptyInput() async {
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))))
        #expect(await service.clean("") == "")
    }

    @Test func cleanFallsBackToRawWhenOutputFailsSanityChecks() async {
        // A truncated <think> block means the whole output is chain-of-thought.
        let service = makeService(FakeClient(result: .success(
            (json(#"{"response":"<think>The user wants me to"}"#), response(200)))))
        #expect(await service.clean("raw dictation") == "raw dictation")
    }

    // MARK: - status()

    @Test func statusIsOffWhenDisabledWithoutTouchingTheNetwork() async {
        // The client would throw if invoked; a disabled service must not call it.
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))), enabled: false)
        #expect(await service.status() == .off)
    }

    @Test func statusIsActiveWhenSelectedModelInstalled() async {
        let data = json(#"{"models":[{"name":"qwen3:4b-instruct"},{"name":"other:1b"}]}"#)
        let service = makeService(FakeClient(result: .success((data, response(200)))))
        service.model = "qwen3:4b-instruct"
        #expect(await service.status() == .active(model: "qwen3:4b-instruct"))
    }

    @Test func statusIsUnavailableWhenOllamaIsDown() async {
        let service = makeService(FakeClient(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await service.status() == .unavailable)
    }

    @Test func statusIsUnavailableWhenSelectedModelIsMissing() async {
        let data = json(#"{"models":[{"name":"other:1b"}]}"#)
        let service = makeService(FakeClient(result: .success((data, response(200)))))
        service.model = "qwen3:4b-instruct"
        #expect(await service.status() == .unavailable)
    }

    // MARK: - buildRequest()

    @Test func buildRequestEncodesModelPromptAndHeaders() throws {
        let config = Configuration.Cleanup(model: "llama3.2:3b", temperature: 0.2)
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        let service = CleanupService(
            config: config,
            httpClient: FakeClient(result: .failure(URLError(.badURL))),
            defaults: defaults
        )

        let request = service.buildRequest(for: "hello there")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "llama3.2:3b")
        // The transcript is wrapped in a delimited instruction, so it's embedded
        // rather than sent verbatim.
        #expect((object["prompt"] as? String)?.contains("hello there") == true)
        #expect(object["stream"] as? Bool == false)
        // Guardrails: suppress reasoning, keep the model resident, budget the output.
        #expect(object["think"] as? Bool == false)
        #expect(object["keep_alive"] as? String == "-1m")
        let options = try #require(object["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 100)   // 11 chars × 2, floored at min
    }

    // MARK: - Personal dictionary in the system prompt

    @Test func buildRequestRendersDictionaryIntoSystemPrompt() throws {
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))))
        service.dictionaryProvider = { ["Zied", "WhisperKit"] }

        let body = try #require(service.buildRequest(for: "hello").httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(object["system"] as? String)
        #expect(system.contains("PERSONAL DICTIONARY"))
        #expect(system.contains("Zied, WhisperKit"))
        // The base instructions must survive untouched ahead of the dictionary.
        #expect(system.hasPrefix(Configuration.Cleanup.defaultSystemPrompt))
    }

    @Test func buildRequestLeavesSystemPromptAloneWhenDictionaryIsEmpty() throws {
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))))

        let body = try #require(service.buildRequest(for: "hello").httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["system"] as? String == Configuration.Cleanup.defaultSystemPrompt)
    }

    @Test func warmupRequestSharesDictionaryBearingSystemPrompt() throws {
        // Warm-up exists to prefill the system prompt's KV cache; if it rendered
        // a different system prompt than real requests, the prefill would be
        // wasted and every dictation would pay it again.
        let service = makeService(FakeClient(result: .failure(URLError(.badURL))))
        service.dictionaryProvider = { ["Zied"] }

        func system(of request: URLRequest) throws -> String {
            let body = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(object["system"] as? String)
        }
        #expect(try system(of: service.buildWarmupRequest())
            == system(of: service.buildRequest(for: "hello")))
    }

    // MARK: - warmUp()

    @Test func warmupRequestSharesPromptPrefixAndGeneratesOneToken() throws {
        let config = Configuration.Cleanup(model: "llama3.2:3b", warmupTimeout: 45)
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        let service = CleanupService(
            config: config,
            httpClient: FakeClient(result: .failure(URLError(.badURL))),
            defaults: defaults
        )

        let request = service.buildWarmupRequest()
        #expect(request.httpMethod == "POST")
        // Cold loads can exceed the dictation timeout; the warm-up gets its own.
        #expect(request.timeoutInterval == 45)

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "llama3.2:3b")
        #expect(object["system"] as? String == config.systemPrompt)
        // Same wrapped-prompt shape as a real dictation, so the prefilled KV
        // cache prefix carries over to real requests.
        let realPrompt = try #require(CleanupService.wrapPrompt("x").components(separatedBy: "<<<").first)
        #expect((object["prompt"] as? String)?.hasPrefix(realPrompt) == true)
        // Side effects only — generate as little as possible.
        let options = try #require(object["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 1)
    }

    @Test func warmUpSucceedsAgainstAHealthyServer() async {
        let service = makeService(FakeClient(result: .success((json("{}"), response(200)))))
        #expect(await service.warmUp() == true)
    }

    @Test func warmUpSkipsNetworkWhenDisabled() async {
        // The 200 response would report success; disabled must not get there.
        let service = makeService(FakeClient(result: .success((json("{}"), response(200)))), enabled: false)
        #expect(await service.warmUp() == false)
    }

    @Test func warmUpReportsFailureWhenOllamaIsDown() async {
        let service = makeService(FakeClient(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await service.warmUp() == false)
    }

    // MARK: - timingSummary()

    @Test func timingSummaryRendersOllamaDurations() {
        let data = json("""
        {"response":"Hi.","total_duration":7020000000,"load_duration":5100000000,
         "prompt_eval_count":1312,"prompt_eval_duration":1520000000,
         "eval_count":24,"eval_duration":310000000}
        """)
        #expect(CleanupService.timingSummary(data: data)
                == "total 7.02s: load 5.10s, prefill 1312tk 1.52s, generate 24tk 0.31s")
    }

    @Test func timingSummaryIsNilWithoutTimingFields() {
        #expect(CleanupService.timingSummary(data: json(#"{"response":"Hi."}"#)) == nil)
        #expect(CleanupService.timingSummary(data: json("nope")) == nil)
    }

    @Test func responseTokenBudgetScalesWithInputAndClamps() {
        let config = Configuration.Cleanup(
            minResponseTokens: 100, maxResponseTokens: 2_048, responseTokenMultiplier: 2)
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        let service = CleanupService(
            config: config, httpClient: FakeClient(result: .failure(URLError(.badURL))),
            defaults: defaults)

        #expect(service.responseTokenBudget(for: "short") == 100)                        // floor
        #expect(service.responseTokenBudget(for: String(repeating: "a", count: 300)) == 600)
        #expect(service.responseTokenBudget(for: String(repeating: "a", count: 5_000)) == 2_048) // cap
    }

    // MARK: - model selection

    @Test func modelDefaultsToConfigAndPersistsUserChoice() {
        let defaults = UserDefaults(suiteName: "zwispTests-\(UUID().uuidString)")!
        let config = Configuration.Cleanup(model: "llama3.2:3b")
        let client = FakeClient(result: .failure(URLError(.badURL)))

        let service = CleanupService(config: config, httpClient: client, defaults: defaults)
        #expect(service.model == "llama3.2:3b")

        service.model = "qwen3:4b"
        // A fresh service over the same defaults sees the persisted pick.
        let reloaded = CleanupService(config: config, httpClient: client, defaults: defaults)
        #expect(reloaded.model == "qwen3:4b")
        // And the request uses it.
        let body = reloaded.buildRequest(for: "hi").httpBody!
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(object["model"] as? String == "qwen3:4b")
    }

    @Test func parseModelListExtractsNames() {
        let data = json(#"{"models":[{"name":"llama3.2:3b","size":1},{"name":"qwen3:4b"}]}"#)
        #expect(CleanupService.parseModelList(data: data, response: response(200))
                == ["llama3.2:3b", "qwen3:4b"])
    }

    @Test func parseModelListReturnsNilForNon200OrMalformed() {
        #expect(CleanupService.parseModelList(data: json(#"{"models":[]}"#), response: response(500)) == nil)
        #expect(CleanupService.parseModelList(data: json("nope"), response: response(200)) == nil)
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
