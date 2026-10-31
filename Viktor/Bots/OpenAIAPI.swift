import Foundation

/// ChatGPT over OpenAI's Responses API, for bots that run on this Mac. OpenAI keeps each
/// conversation (store: true), so a run can pause for the user's OK and continue later with
/// `previous_response_id`. Needs an OpenAI API key (Settings → Accounts → ChatGPT); a ChatGPT
/// subscription doesn't include API use.
enum OpenAIAPI {
    static let keyAccount = "openai"
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    @MainActor static var isConfigured: Bool { Secrets.get(keyAccount)?.isEmpty == false || OrbitCloud.shared.usesPro }

    struct APIError: LocalizedError, Equatable {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    /// Starts a run: instructions, the first message and the bot's tools.
    @MainActor
    static func start(model: String, instructions: String, message: String, tools: [[String: Any]]) async throws -> Turn {
        var body: [String: Any] = ["model": model, "instructions": instructions, "input": message, "store": true]
        if !tools.isEmpty { body["tools"] = tools }
        return try await send(body)
    }

    /// Continues a run with the results of the tool calls it asked for.
    @MainActor
    static func resume(model: String, instructions: String, previous: String, outputs: [(callID: String, output: String)],
                       tools: [[String: Any]]) async throws -> Turn {
        try await send([
            "model": model,
            // Instructions aren't carried over from the previous response, so send them again.
            "instructions": instructions,
            "previous_response_id": previous,
            "input": outputs.map { ["type": "function_call_output", "call_id": $0.callID, "output": $0.output] },
            "tools": tools,
            "store": true,
        ])
    }

    @MainActor
    private static func send(_ body: [String: Any]) async throws -> Turn {
        if OrbitCloud.shared.usesPro {
            do {
                let data = try await OrbitCloud.shared.function("openai", path: "/responses", body: body)
                return Turn((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            } catch let e as OrbitCloud.CloudError {
                if case .http(let code, let text) = e { throw APIError(status: code, message: text ?? e.localizedDescription) }
                throw APIError(status: 0, message: e.localizedDescription)
            }
        }
        guard let key = Secrets.get(keyAccount), !key.isEmpty else {
            throw APIError(status: 0, message: "Add your OpenAI API key in Settings → Accounts → ChatGPT.")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<2 {
            let data: Data, response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: req) }
            catch { throw APIError(status: 0, message: "Couldn't reach OpenAI. Check your internet connection.") }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 || code >= 500, attempt == 0 {
                let wait = min(Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 5, 30)
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard (200..<300).contains(code) else { throw error(code, json) }
            return Turn(json)
        }
        throw APIError(status: 429, message: "OpenAI is busy or rate-limiting this key. Orbit will try again shortly.")
    }

    nonisolated static func error(_ code: Int, _ json: [String: Any]) -> APIError {
        let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
        switch code {
        case 401: return APIError(status: code, message: "OpenAI rejected the API key. Check it in Settings → Accounts → ChatGPT.")
        case 429: return APIError(status: code, message: "OpenAI is rate-limiting this key, or it's out of credit. \(detail)")
        default: return APIError(status: code, message: "OpenAI: \(detail)")
        }
    }

    /// One response: what ChatGPT wrote and which tools it wants to call.
    struct Turn: Equatable {
        struct Call: Equatable, Codable {
            let callID: String
            let name: String
            let arguments: String
        }

        var id: String
        var model: String
        var status: String
        var texts: [String] = []
        var calls: [Call] = []
        var error: String?
        var inputTokens = 0
        var outputTokens = 0
        var webSearches = 0

        init(_ json: [String: Any]) {
            id = json["id"] as? String ?? ""
            model = json["model"] as? String ?? ""
            status = json["status"] as? String ?? "completed"
            for item in json["output"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "message":
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "output_text" }
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { texts.append(text) }
                case "web_search_call":
                    webSearches += 1
                case "function_call":
                    if let callID = item["call_id"] as? String, let name = item["name"] as? String {
                        calls.append(Call(callID: callID, name: name, arguments: item["arguments"] as? String ?? "{}"))
                    }
                default:
                    break
                }
            }
            if let e = json["error"] as? [String: Any] { error = e["message"] as? String }
            if status == "incomplete", error == nil {
                let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
                error = "ChatGPT stopped early (\(reason ?? "incomplete"))."
            }
            let usage = json["usage"] as? [String: Any]
            inputTokens = usage?["input_tokens"] as? Int ?? 0
            outputTokens = usage?["output_tokens"] as? Int ?? 0
        }
    }
}
