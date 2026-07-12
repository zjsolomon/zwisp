import Foundation

/// `CleanupEngine` backed by the llama-server bundled inside zwisp.app,
/// reached over localhost HTTP. The pure pieces — the ChatML prompt render,
/// the `/completion` request body, the response and `/health` parsers — are
/// static and unit-tested; network delivery goes through the same `HTTPClient`
/// seam `CleanupService` always used, so tests inject a fake.
///
/// The base URL is a closure, not a value: the supervisor may move the server
/// to a neighbouring port when the configured one is taken, and every request
/// must follow it.
public final class LlamaServerClient: CleanupEngine {
    private let config: Configuration.Cleanup
    private let httpClient: HTTPClient
    private let baseURL: () -> URL

    /// Production initializer: real URLSession against the configured port.
    public convenience init(config: Configuration.Cleanup) {
        let url = URL(string: "http://127.0.0.1:\(config.server.port)")!
        self.init(config: config, httpClient: URLSession.shared, baseURL: { url })
    }

    public init(config: Configuration.Cleanup, httpClient: HTTPClient,
                baseURL: @escaping () -> URL) {
        self.config = config
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    // MARK: - CleanupEngine

    public func generate(system: String, prompt: String, maxTokens: Int,
                         timeout: TimeInterval) async throws -> CleanupGeneration {
        let request = buildCompletionRequest(
            system: system, prompt: prompt, maxTokens: maxTokens, timeout: timeout)
        let (data, response) = try await httpClient.data(for: request)
        guard let generation = Self.parseCompletion(data: data, response: response) else {
            throw LlamaServerError.unusableResponse
        }
        return generation
    }

    public func isReady() async -> Bool {
        var request = URLRequest(url: baseURL().appendingPathComponent("health"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await httpClient.data(for: request) else {
            return false
        }
        return Self.parseHealth(data: data, response: response)
    }

    // MARK: - Request building (internal so tests can assert the body)

    /// Qwen3's ChatML template, rendered by hand so the prompt string is
    /// deterministic: llama-server's longest-common-prefix KV reuse depends on
    /// consecutive requests sharing their rendered prefix byte for byte
    /// (system prompt first, so a warm-up's prefill carries over).
    static func chatML(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n"
            + "<|im_start|>user\n\(user)<|im_end|>\n"
            + "<|im_start|>assistant\n"
    }

    func buildCompletionRequest(system: String, prompt: String, maxTokens: Int,
                                timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL().appendingPathComponent("completion"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let body: [String: Any] = [
            "prompt": Self.chatML(system: system, user: prompt),
            "n_predict": maxTokens,
            "temperature": config.temperature,
            // Keep the slot's KV cache across requests: a dictation re-prefills
            // only what changed since the warm-up, not the whole system prompt.
            "cache_prompt": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Parsing

    /// Extracts the generated text and the `timings` block from a 200
    /// `/completion` response, or `nil` when the response isn't usable.
    /// `content` may legitimately be a lone token (a warm-up generates exactly
    /// one), so emptiness is the caller's concern, not a parse failure.
    static func parseCompletion(data: Data, response: URLResponse) -> CleanupGeneration? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? String
        else { return nil }
        return CleanupGeneration(text: content, timings: parseTimings(object["timings"]))
    }

    /// llama-server reports milliseconds; `draft_n`/`draft_n_accepted` appear
    /// only when speculative decoding ran for the request.
    private static func parseTimings(_ value: Any?) -> CleanupGeneration.Timings? {
        guard let timings = value as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (timings[key] as? NSNumber)?.intValue ?? 0 }
        func seconds(_ key: String) -> Double {
            ((timings[key] as? NSNumber)?.doubleValue ?? 0) / 1e3
        }
        return CleanupGeneration.Timings(
            prefillTokens: int("prompt_n"),
            prefillSeconds: seconds("prompt_ms"),
            generatedTokens: int("predicted_n"),
            generatedSeconds: seconds("predicted_ms"),
            draftTokens: (timings["draft_n"] as? NSNumber)?.intValue,
            draftAccepted: (timings["draft_n_accepted"] as? NSNumber)?.intValue)
    }

    /// Public: the app-layer supervisor reuses this exact parse for its own
    /// startup health poll, so "healthy" means the same thing in both places.
    public static func parseHealth(data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["status"] as? String == "ok"
    }
}

/// The engine reached the server but couldn't use what came back (non-200,
/// malformed JSON). Unreachability surfaces as the transport's own error.
public enum LlamaServerError: Error {
    case unusableResponse
}
