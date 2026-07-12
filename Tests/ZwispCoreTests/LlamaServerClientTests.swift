import Testing
import Foundation
@testable import ZwispCore

struct LlamaServerClientTests {
    /// A fake HTTP client that returns a canned result (or throws) and records
    /// the request, so bodies and URLs are asserted without a server.
    private final class FakeClient: HTTPClient, @unchecked Sendable {
        var result: Result<(Data, URLResponse), Error>
        private(set) var capturedRequest: URLRequest?

        init(result: Result<(Data, URLResponse), Error>) {
            self.result = result
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequest = request
            return try result.get()
        }
    }

    private let base = URL(string: "http://127.0.0.1:43917")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func json(_ string: String) -> Data { Data(string.utf8) }

    private func makeClient(_ httpClient: HTTPClient,
                            baseURL: @escaping () -> URL = { URL(string: "http://127.0.0.1:43917")! }) -> LlamaServerClient {
        LlamaServerClient(config: Configuration.Cleanup(), httpClient: httpClient,
                          baseURL: baseURL)
    }

    // MARK: - ChatML render

    @Test func chatMLRendersQwenTemplate() {
        let rendered = LlamaServerClient.chatML(system: "SYS", user: "USER")
        #expect(rendered == "<|im_start|>system\nSYS<|im_end|>\n"
                + "<|im_start|>user\nUSER<|im_end|>\n"
                + "<|im_start|>assistant\n")
    }

    @Test func chatMLKeepsSystemFirstSoKVPrefixCarriesOver() {
        // KV reuse depends on consecutive prompts sharing their rendered prefix:
        // two requests with the same system prompt must agree byte-for-byte up
        // to the user turn.
        let a = LlamaServerClient.chatML(system: "SHARED", user: "first")
        let b = LlamaServerClient.chatML(system: "SHARED", user: "second")
        let sharedPrefix = "<|im_start|>system\nSHARED<|im_end|>\n<|im_start|>user\n"
        #expect(a.hasPrefix(sharedPrefix))
        #expect(b.hasPrefix(sharedPrefix))
    }

    // MARK: - Request building

    @Test func generateTargetsCompletionEndpointWithBodyAndTimeout() async throws {
        let fake = FakeClient(result: .success(
            (json(#"{"content":"Cleaned."}"#), response(200))))
        let client = makeClient(fake)

        _ = try await client.generate(system: "SYS", prompt: "USER", maxTokens: 128, timeout: 8)

        let request = try #require(fake.capturedRequest)
        #expect(request.url == base.appendingPathComponent("completion"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 8)

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["prompt"] as? String == LlamaServerClient.chatML(system: "SYS", user: "USER"))
        #expect(object["n_predict"] as? Int == 128)
        #expect(object["temperature"] as? Double == Configuration.Cleanup().temperature)
        // The slot's KV cache must survive across requests, or every dictation
        // re-prefills the whole system prompt.
        #expect(object["cache_prompt"] as? Bool == true)
    }

    @Test func requestsFollowTheBaseURLProvider() async throws {
        // The supervisor may move the server to a neighbouring port; every
        // request must ask the provider rather than bake in a URL.
        final class PortBox: @unchecked Sendable { var port = 43917 }
        let box = PortBox()
        let fake = FakeClient(result: .success(
            (json(#"{"content":"x"}"#), response(200))))
        let client = makeClient(fake, baseURL: { URL(string: "http://127.0.0.1:\(box.port)")! })

        box.port = 43919
        _ = try await client.generate(system: "s", prompt: "p", maxTokens: 1, timeout: 1)
        #expect(fake.capturedRequest?.url?.port == 43919)
    }

    // MARK: - Response parsing

    @Test func parseCompletionExtractsContentAndTimings() {
        let data = json("""
        {"content":" Cleaned text. ",
         "timings":{"prompt_n":176,"prompt_ms":1720.5,"predicted_n":173,"predicted_ms":4650.0,
                    "draft_n":216,"draft_n_accepted":134}}
        """)
        let generation = LlamaServerClient.parseCompletion(data: data, response: response(200))
        // Content passes through unmodified (trimming is the caller's concern —
        // a warm-up's single token may be pure whitespace and still succeed).
        #expect(generation?.text == " Cleaned text. ")
        let timings = generation?.timings
        #expect(timings?.prefillTokens == 176)
        #expect(abs((timings?.prefillSeconds ?? 0) - 1.7205) < 0.0001)
        #expect(timings?.generatedTokens == 173)
        #expect(abs((timings?.generatedSeconds ?? 0) - 4.65) < 0.0001)
        #expect(timings?.draftTokens == 216)
        #expect(timings?.draftAccepted == 134)
    }

    @Test func parseCompletionOmitsDraftFieldsWhenSpeculationIsOff() {
        let data = json(#"{"content":"x","timings":{"prompt_n":10,"prompt_ms":50,"predicted_n":5,"predicted_ms":100}}"#)
        let timings = LlamaServerClient.parseCompletion(data: data, response: response(200))?.timings
        #expect(timings != nil)
        #expect(timings?.draftTokens == nil)
        #expect(timings?.draftAccepted == nil)
    }

    @Test func parseCompletionSurvivesMissingTimings() {
        let generation = LlamaServerClient.parseCompletion(
            data: json(#"{"content":"x"}"#), response: response(200))
        #expect(generation?.text == "x")
        #expect(generation?.timings == nil)
    }

    @Test func parseCompletionReturnsNilForNon200OrMalformed() {
        #expect(LlamaServerClient.parseCompletion(
            data: json(#"{"content":"x"}"#), response: response(503)) == nil)
        #expect(LlamaServerClient.parseCompletion(
            data: json("not json"), response: response(200)) == nil)
        #expect(LlamaServerClient.parseCompletion(
            data: json(#"{"error":"loading model"}"#), response: response(200)) == nil)
    }

    @Test func generateThrowsOnUnusableResponse() async {
        let client = makeClient(FakeClient(result: .success((json("busy"), response(503)))))
        await #expect(throws: LlamaServerError.unusableResponse) {
            _ = try await client.generate(system: "s", prompt: "p", maxTokens: 1, timeout: 1)
        }
    }

    // MARK: - /health

    @Test func isReadyTrueOnHealthOK() async {
        let fake = FakeClient(result: .success((json(#"{"status":"ok"}"#), response(200))))
        let client = makeClient(fake)
        #expect(await client.isReady() == true)
        #expect(fake.capturedRequest?.url == base.appendingPathComponent("health"))
    }

    @Test func isReadyFalseWhileLoadingOrDown() async {
        // llama-server answers 503 {"status":"loading model"} during startup.
        let loading = makeClient(FakeClient(result: .success(
            (json(#"{"status":"loading model"}"#), response(503)))))
        #expect(await loading.isReady() == false)

        let down = makeClient(FakeClient(result: .failure(URLError(.cannotConnectToHost))))
        #expect(await down.isReady() == false)
    }
}
