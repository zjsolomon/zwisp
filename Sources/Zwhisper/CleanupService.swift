import Foundation

/// Optional LLM "cleanup" pass that turns a raw speech transcript into clean
/// written text (punctuation, capitalization, removing filler words and false
/// starts). Runs fully locally against an Ollama server on localhost.
///
/// If Ollama isn't installed/running, `clean` simply returns the original text,
/// so dictation always works.
final class CleanupService {
    /// User-toggleable from the menu; persisted in UserDefaults.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "cleanupEnabled") }
    }

    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    // Any small instruct model you've pulled in Ollama, e.g. `ollama pull llama3.2:3b`.
    private let model = "llama3.2:3b"

    private let systemPrompt = """
    You clean up raw speech-to-text dictation into polished written text.
    - Fix punctuation, capitalization, and obvious transcription mistakes.
    - Remove filler words (um, uh, like) and false starts / self-corrections, \
    keeping the speaker's intended wording and meaning.
    - Do NOT add new content, do NOT answer questions, do NOT add commentary or quotes.
    Output ONLY the cleaned text, nothing else.
    """

    init() {
        // Default ON; respect a previously saved choice.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "cleanupEnabled") == nil {
            enabled = true
        } else {
            enabled = defaults.bool(forKey: "cleanupEnabled")
        }
    }

    func clean(_ text: String) async -> String {
        guard enabled, !text.isEmpty else { return text }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "prompt": text,
            "stream": false,
            "options": ["temperature": 0.2]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cleaned = (object["response"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !cleaned.isEmpty
            else {
                return text
            }
            return cleaned
        } catch {
            NSLog("Zwhisper: cleanup unavailable (\(error.localizedDescription)); using raw text")
            return text
        }
    }
}
