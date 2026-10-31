import Foundation

/// Talks to the Claude API (Messages endpoint) over HTTPS with your own API key from the Keychain.
/// Swift has no official Anthropic SDK, so this sends the documented raw HTTP request.
@MainActor
enum ClaudeAPI {
    static let model = "claude-opus-5-5"
    static let keyAccount = "anthropic"

    static var isConfigured: Bool { Secrets.get(keyAccount)?.isEmpty == false }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One Messages API call. `messages` are sent exactly as given (append-only history, including
    /// any thinking or fallback blocks from earlier responses). Returns the response JSON.
    ///
    /// - Opus 5.5 with adaptive thinking (the default) at `effort` (low = quick answers).
    /// - Server-side refusal fallback: if Opus declines, the API retries on a suitable model itself.
    /// - Top-level prompt caching for the stable system prompt and tools.
    static func send(system: String,
                     messages: [[String: Any]],
                     tools: [[String: Any]] = [],
                     effort: String = "low",
                     maxTokens: Int = 16000) async throws -> [String: Any] {
        guard let key = Secrets.get(keyAccount), !key.isEmpty else {
            throw APIError(message: "Add your Anthropic API key in Settings → Accounts → Claude.")
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError(message: "Couldn't reach Claude. Check your internet connection.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard code == 200 else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            switch code {
            case 401: throw APIError(message: "Claude rejected the API key. Check it in Settings → Accounts.")
            case 429: throw APIError(message: "Claude is rate-limiting this key. Try again in a moment.")
            case 529, 503: throw APIError(message: "Claude is busy right now. Try again in a moment.")
            default: throw APIError(message: "Claude: \(detail)")
            }
        }
        return json
    }

    /// All text blocks of a response, joined.
    static func text(_ content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
