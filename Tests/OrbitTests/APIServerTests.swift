import Foundation
import Testing
@testable import Orbit
@testable import OrbitKit

@Suite("HTTP parsing")
@MainActor struct HTTPTests {
    @Test func parsesCompleteRequest() throws {
        let raw = "POST /v1/items?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 5\r\n\r\nhello"
        let req = try #require(HTTPRequest.parse(Data(raw.utf8)))
        #expect(req.method == "POST")
        #expect(req.path == "/v1/items")
        #expect(req.header("authorization") == "Bearer abc")
        #expect(String(decoding: req.body, as: UTF8.self) == "hello")
    }

    @Test func waitsForTheWholeBody() {
        let raw = "POST /v1/items HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello"
        #expect(HTTPRequest.parse(Data(raw.utf8)) == nil)
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == nil)
    }

    @Test func serializesResponse() {
        let text = String(decoding: HTTPResponse.error(404, "Nope").serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(text.hasSuffix(#"{"error":"Nope"}"#))
    }
}

@Suite("Agents: API routing and Claude hooks")
@MainActor
struct AgentsTests {
    private func request(_ method: String, _ path: String, _ body: String = "") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: [:], body: Data(body.utf8))
    }

    @Test func itemsCreateUpdateListDelete() async throws {
        let agents = AgentsModule(alerts: AlertCenter())
        var r = await agents.handle(request("POST", "/v1/items", #"{"id":"t","title":"Tests","progress":0.5,"status":"active","updated":"2026-10-27T10:00:00Z"}"#))
        #expect(r.status == 200)
        r = await agents.handle(request("POST", "/v1/items", #"{"id":"t","title":"Tests","progress":1,"status":"success","updated":"2026-10-27T10:00:00Z"}"#))
        #expect(r.status == 200)
        #expect(agents.items.count == 1)
        #expect(agents.items.first?.status == .success)
        r = await agents.handle(request("GET", "/v1/items"))
        let list = try APIJSON.decoder.decode([APIItem].self, from: r.body)
        #expect(list.map(\.id) == ["t"])
        r = await agents.handle(request("DELETE", "/v1/items/t"))
        #expect(r.status == 200)
        r = await agents.handle(request("DELETE", "/v1/items/t"))
        #expect(r.status == 404)
    }

    @Test func badRequestsAreRejected() async {
        let agents = AgentsModule(alerts: AlertCenter())
        #expect(await agents.handle(request("POST", "/v1/items", "not json")).status == 400)
        #expect(await agents.handle(request("POST", "/v1/ask", #"{"title":"x","actions":[]}"#)).status == 400)
        #expect(await agents.handle(request("GET", "/v1/nope")).status == 404)
        #expect(await agents.handle(request("GET", "/v1/status")).status == 200)
    }

    @Test func claudeHookLifecycle() async {
        let agents = AgentsModule(alerts: AlertCenter())
        func hook(_ event: String, _ extra: String = "") async {
            _ = await agents.handle(request("POST", "/v1/hooks/claude",
                #"{"session_id":"s1","hook_event_name":"\#(event)","cwd":"/Users/x/acme-web"\#(extra)}"#))
        }
        await hook("SessionStart")
        #expect(agents.sessions.first?.state == .working)
        #expect(agents.sessions.first?.project == "acme-web")
        await hook("PreToolUse", #","tool_name":"Edit","tool_input":{"file_path":"/a/b/Hero.tsx"}"#)
        #expect(agents.sessions.first?.detail == "Editing Hero.tsx")
        await hook("PreToolUse", #","tool_name":"Bash","tool_input":{"command":"npm run build\nmore"}"#)
        #expect(agents.sessions.first?.detail == "Running npm run build")
        #expect(agents.runningCount == 1)
        await hook("Notification", #","message":"Claude needs your permission to use Bash""#)
        #expect(agents.sessions.first?.state == .needsInput)
        #expect(agents.attention?.headline == "Claude needs you")
        await hook("Stop")
        #expect(agents.sessions.first?.state == .done)
        #expect(agents.usage.toolRuns == 2)
        #expect(agents.usage.sessions == ["s1"])
        await hook("SessionEnd")
        #expect(agents.sessions.isEmpty)
    }

    @Test func askIsAnsweredByAButton() async throws {
        let agents = AgentsModule(alerts: AlertCenter())
        let task = Task { await agents.handle(request("POST", "/v1/ask", #"{"title":"Deploy?","actions":["Cancel","Deploy"],"timeout":30}"#)) }
        for _ in 0..<50 where agents.asks.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let ask = try #require(agents.asks.first)
        #expect(agents.attention?.headline == "Question waiting")
        agents.answer(ask.id, with: "Deploy")
        let response = await task.value
        #expect(response.status == 200)
        #expect(try APIJSON.decoder.decode(AskResponse.self, from: response.body).choice == "Deploy")
        #expect(agents.asks.isEmpty)
    }
}
