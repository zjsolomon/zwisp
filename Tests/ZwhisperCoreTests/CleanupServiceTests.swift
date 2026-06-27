import Testing
import Foundation
@testable import ZwhisperCore

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
        let defaults = UserDefaults(suiteName: "ZwhisperTests-\(UUID().uuidString)")!
        let service = CleanupService(config: Configuration.Cleanup(), httpClient: client, defaults: defaults)
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

    // MARK: - buildRequest()

    @Test func buildRequestEncodesModelPromptAndHeaders() throws {
        let config = Configuration.Cleanup(model: "llama3.2:3b", temperature: 0.2)
        let defaults = UserDefaults(suiteName: "ZwhisperTests-\(UUID().uuidString)")!
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
        #expect(object["prompt"] as? String == "hello there")
        #expect(object["stream"] as? Bool == false)
    }
}
