import Foundation

/// Claude Managed Agents over plain HTTPS (there's no Swift SDK). Bots run here: each bot is an
/// agent, its schedule is a deployment, and every run is a session. Uses the same API key as
/// Smart Ask (Settings → Accounts → Claude). All calls for this beta go through this one file.
enum ManagedAgentsAPI {
    static let version = "2026-10-21"
    static let beta = "managed-agents-2026-04-01"
    private static let base = "https://api.anthropic.com/v1/"

    struct APIError: LocalizedError, Equatable {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor static var isConfigured: Bool { ClaudeAPI.isConfigured || OrbitCloud.shared.usesPro }

    // MARK: Requests

    /// One JSON request. Retries once after a 429, waiting what the server asks (at most 30 s).
    @MainActor
    static func call(_ method: String, _ path: String, body: [String: Any]? = nil,
                     query: [String: String] = [:]) async throws -> [String: Any] {
        if CloudMode.active == .pro {
            // Orbit Pro: the same request, through Orbit's server (which adds Orbit's key).
            do {
                let data = try await OrbitCloud.shared.function("claude", method: method, path: "/" + path, body: body, query: query)
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } catch let e as OrbitCloud.CloudError {
                if case .http(let code, let text) = e { throw APIError(status: code, message: text ?? e.localizedDescription) }
                throw APIError(status: 0, message: e.localizedDescription)
            }
        }
        guard let key = Secrets.get(ClaudeAPI.keyAccount), !key.isEmpty else {
            throw APIError(status: 0, message: "Add your Anthropic API key in Settings → Accounts → Claude.")
        }
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<2 {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                throw APIError(status: 0, message: "Couldn't reach Anthropic. Check your internet connection.")
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429, attempt == 0 {
                let wait = min(Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 5, 30)
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard (200..<300).contains(code) else { throw Self.error(code, json) }
            return json
        }
        throw APIError(status: 429, message: "Anthropic is rate-limiting this key. Orbit will try again shortly.")
    }

    nonisolated static func error(_ code: Int, _ json: [String: Any]) -> APIError {
        let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
        switch code {
        case 401: return APIError(status: code, message: "Anthropic rejected the API key. Check it in Settings → Accounts → Claude.")
        case 403: return APIError(status: code, message: "This API key can't use bots yet (Managed Agents). \(detail)")
        case 429: return APIError(status: code, message: "Anthropic is rate-limiting this key. Orbit will try again shortly.")
        case 500..<600: return APIError(status: code, message: "Anthropic is having trouble right now. Orbit will try again shortly.")
        default: return APIError(status: code, message: detail)
        }
    }

    // MARK: Environments, agents, deployments

    /// A cloud sandbox. Without `web`, it reaches nothing beyond Anthropic: Orbit's bots only use
    /// tools Orbit answers. With `web`, web search and fetch can reach any site (the bots' shell and
    /// file tools stay off, so nothing else uses that access).
    @MainActor
    static func createEnvironment(web: Bool = false) async throws -> String {
        if CloudMode.active == .pro {
            // Orbit Pro uses Orbit's shared sandboxes.
            return try id(try await call("GET", "orbit/environment", query: web ? ["web": "1"] : [:]))
        }
        let networking: [String: Any] = web
            ? ["type": "unrestricted"]
            : ["type": "limited", "allow_package_managers": false, "allow_mcp_servers": false]
        let json = try await call("POST", "environments", body: [
            "name": web ? "Orbit Bots · web" : "Orbit Bots",
            "config": ["type": "cloud", "networking": networking] as [String: Any],
        ])
        return try id(json)
    }

    /// Answers a built-in tool call that paused for permission (only web search and fetch are allowed).
    @MainActor
    static func confirm(_ sessionID: String, toolUseID: String, allow: Bool) async throws {
        var event: [String: Any] = ["type": "user.tool_confirmation", "tool_use_id": toolUseID, "result": allow ? "allow" : "deny"]
        if !allow { event["deny_message"] = "Orbit only lets bots search and read the web." }
        _ = try await call("POST", "sessions/\(sessionID)/events", body: ["events": [event]])
    }

    /// Creates the agent, or updates it (a new version) when `id` is given. Returns (id, version).
    @MainActor
    static func saveAgent(id existing: String?, _ config: [String: Any]) async throws -> (String, Int) {
        let json = try await call("POST", existing.map { "agents/\($0)" } ?? "agents", body: config)
        return (try id(json), json["version"] as? Int ?? 1)
    }

    /// Creates or updates the deployment that runs a bot on its schedule.
    @MainActor
    static func saveDeployment(id existing: String?, _ body: [String: Any]) async throws -> String {
        try id(try await call("POST", existing.map { "deployments/\($0)" } ?? "deployments", body: body))
    }

    @MainActor
    static func setDeploymentPaused(_ id: String, _ paused: Bool) async throws {
        _ = try await call("POST", "deployments/\(id)/\(paused ? "pause" : "unpause")", body: [:])
    }

    @MainActor
    static func runDeployment(_ id: String) async throws {
        _ = try await call("POST", "deployments/\(id)/run", body: [:])
    }

    struct Run: Equatable {
        let id: String
        let sessionID: String?
        let error: String?
        let createdAt: Date?
    }

    @MainActor
    static func recentRuns(deploymentID: String, limit: Int = 5) async throws -> [Run] {
        let json = try await call("GET", "deployment_runs", query: ["deployment_id": deploymentID, "limit": "\(limit)"])
        return parseRuns(json)
    }

    nonisolated static func parseRuns(_ json: [String: Any]) -> [Run] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            let err = r["error"] as? [String: Any]
            return Run(id: id, sessionID: r["session_id"] as? String,
                       error: err.map { ($0["message"] as? String) ?? ($0["type"] as? String) ?? "Failed" },
                       createdAt: (r["created_at"] as? String).flatMap(parseDate))
        }
    }

    // MARK: Sessions

    /// Starts a run right away with a first message (used for meeting prep and "Run now" with a twist).
    @MainActor
    static func startSession(agentID: String, environmentID: String, title: String, message: String,
                             budgetCents: Int, botID: String) async throws -> String {
        try id(try await call("POST", "sessions", body: [
            "agent": agentID,
            "environment_id": environmentID,
            "title": title,
            "metadata": ["orbit_bot": botID],
            "budget": budget(budgetCents),
            "initial_events": [userMessage(message)],
        ]))
    }

    /// "running", "idle", "rescheduling" or "terminated".
    @MainActor
    static func sessionStatus(_ id: String) async throws -> String {
        try await call("GET", "sessions/\(id)")["status"] as? String ?? "unknown"
    }

    /// Every event of a session, oldest first, following pages.
    @MainActor
    static func events(_ sessionID: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var page: String?
        repeat {
            var q = ["limit": "1000"]
            if let page { q["page"] = page }
            let json = try await call("GET", "sessions/\(sessionID)/events", query: q)
            all += json["data"] as? [[String: Any]] ?? []
            page = json["next_page"] as? String
        } while page != nil && all.count < 20_000
        return all
    }

    /// Answers a tool call the bot is waiting on.
    @MainActor
    static func answer(_ sessionID: String, toolUseID: String, text: String, isError: Bool) async throws {
        var event: [String: Any] = [
            "type": "user.custom_tool_result",
            "custom_tool_use_id": toolUseID,
            "content": [["type": "text", "text": text]],
        ]
        if isError { event["is_error"] = true }
        _ = try await call("POST", "sessions/\(sessionID)/events", body: ["events": [event]])
    }

    // MARK: Building blocks

    nonisolated static func userMessage(_ text: String) -> [String: Any] {
        ["type": "user.message", "content": [["type": "text", "text": text]]]
    }

    /// A hard spend cap in US cents (the API takes minor units as a string).
    nonisolated static func budget(_ cents: Int) -> [String: Any] {
        ["type": "limit", "max_list_cost": ["amount": "\(max(cents, 1))", "currency": "USD"]]
    }

    nonisolated static func id(_ json: [String: Any]) throws -> String {
        guard let id = json["id"] as? String, !id.isEmpty else {
            throw APIError(status: 0, message: "Anthropic sent an unexpected answer (no id).")
        }
        return id
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Whose keys a cloud call uses: your own Anthropic key, or Orbit Pro through Orbit's server.
/// A run keeps the mode it started in (set with `CloudMode.$override.withValue`).
enum CloudMode: String, Codable, Sendable {
    case own, pro

    @TaskLocal static var override: CloudMode?

    @MainActor static var current: CloudMode { OrbitCloud.shared.usesPro ? .pro : .own }
    @MainActor static var active: CloudMode { override ?? current }
}

/// What a session's event list says: what the bot wrote, which tool calls still wait for Orbit,
/// and whether the run is over. Pure, so it's easy to test.
struct SessionDigest: Equatable {
    struct ToolUse: Equatable {
        let id: String
        let name: String
        let inputJSON: String

        var input: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any]) ?? [:]
        }
    }

    enum Outcome: Equatable {
        case working
        case waitingForOrbit
        case finished
        case budgetReached
        case failed(String)
    }

    var messages: [String] = []
    var pending: [ToolUse] = []
    /// Built-in tool calls (web search, fetch) waiting for permission: (event id, tool name).
    var confirmations: [ToolUse] = []
    var webSearches = 0
    var outcome: Outcome = .working
    /// Spend so far in US cents, from the latest usage snapshot.
    var costCents: Int?

    /// The bot's answer: its last message.
    var report: String? { messages.last }

    init(events: [[String: Any]]) {
        var uses: [ToolUse] = []
        var answered: Set<String> = []
        var asks: [ToolUse] = []
        var confirmed: Set<String> = []
        var lastError: String?
        for e in events {
            switch e["type"] as? String {
            case "agent.message":
                let text = (e["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { messages.append(text) }
            case "agent.custom_tool_use":
                guard let id = e["id"] as? String else { continue }
                let input = e["input"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                uses.append(ToolUse(id: id, name: e["name"] as? String ?? "", inputJSON: json))
            case "user.custom_tool_result":
                if let id = e["custom_tool_use_id"] as? String { answered.insert(id) }
            case "agent.tool_use", "agent.mcp_tool_use":
                let name = e["name"] as? String ?? ""
                if name == "web_search" || name == "web_fetch" { webSearches += 1 }
                if e["evaluated_permission"] as? String == "ask", let id = e["id"] as? String {
                    asks.append(ToolUse(id: id, name: name, inputJSON: "{}"))
                }
            case "user.tool_confirmation":
                if let id = e["tool_use_id"] as? String { confirmed.insert(id) }
            case "session.usage":
                costCents = Self.cents(e["list_cost"])
            case "session.error":
                lastError = ((e["error"] as? [String: Any])?["message"] as? String) ?? (e["message"] as? String) ?? "The bot hit an error."
            case "session.status_running", "session.status_rescheduled":
                outcome = .working
            case "session.status_idle":
                switch (e["stop_reason"] as? [String: Any])?["type"] as? String {
                case "requires_action": outcome = .waitingForOrbit
                case "end_turn": outcome = .finished
                case "budget_reached": outcome = .budgetReached
                case "retries_exhausted": outcome = .failed(lastError ?? "The bot stopped after repeated errors.")
                default: outcome = .finished
                }
            case "session.status_terminated":
                if outcome == .working || outcome == .waitingForOrbit {
                    outcome = lastError.map { .failed($0) } ?? .finished
                }
            default:
                break
            }
        }
        pending = uses.filter { !answered.contains($0.id) }
        confirmations = asks.filter { !confirmed.contains($0.id) }
        if !(pending.isEmpty && confirmations.isEmpty), outcome != .budgetReached { outcome = .waitingForOrbit }
    }

    /// `{amount, currency}` with amount in cents, as a string or a number.
    static func cents(_ value: Any?) -> Int? {
        guard let cost = value as? [String: Any] else { return nil }
        if let s = cost["amount"] as? String { return Int(s) ?? Double(s).map { Int($0.rounded()) } }
        if let n = cost["amount"] as? NSNumber { return n.intValue }
        return nil
    }

    static func == (a: SessionDigest, b: SessionDigest) -> Bool {
        a.messages == b.messages && a.pending == b.pending && a.outcome == b.outcome && a.costCents == b.costCents
            && a.confirmations == b.confirmations && a.webSearches == b.webSearches
    }
}
