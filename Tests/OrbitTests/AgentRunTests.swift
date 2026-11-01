import Foundation
import Testing
@testable import Orbit
import OrbitKit

@MainActor
struct AgentRunTests {
    @Test func parsesInitTextToolAndResult() {
        #expect(AgentRun.parse(#"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.session("s1")])
        #expect(AgentRun.parse(#"{"type":"system","subtype":"hook_started","session_id":"s1"}"#).isEmpty)
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":" On it. "},{"type":"tool_use","name":"Bash","input":{"command":"npm test\nmore"}}]}}"#
        #expect(AgentRun.parse(assistant) == [.text("On it."), .tool(name: "Bash", summary: "Running npm test")])
        let failed = #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"Permission denied"}]}}"#
        #expect(AgentRun.parse(failed) == [.toolError("Permission denied")])
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s1","total_cost_usd":0.04}"#
        #expect(AgentRun.parse(result) == [.result(sessionID: "s1", text: "Done.", isError: false, cost: 0.04)])
        #expect(AgentRun.parse("not json").isEmpty)
    }

    @Test func runFollowsTheStream() {
        let run = AgentRun(folder: URL(fileURLWithPath: "/tmp/website"))
        run.messages.append(.init(kind: .user, text: "Fix the tests"))
        run.ingest(#"{"type":"system","subtype":"init","session_id":"abc"}"#)
        #expect(run.state == .working)
        #expect(run.claudeSessionID == "abc")
        run.ingest(#"{"type":"assistant","message":{"content":[{"type":"text","text":"All green now."}]}}"#)
        // The final result repeats the last message: it isn't added twice.
        run.ingest(#"{"type":"result","is_error":false,"result":"All green now.","session_id":"abc","total_cost_usd":0.1}"#)
        #expect(run.state == .idle)
        #expect(run.messages.filter { $0.kind == .assistant }.count == 1)
        #expect(run.cost == 0.1)
        #expect(run.name == "website")
        #expect(run.title == "Fix the tests")
    }

    @Test func signInFailureShowsAsFailed() {
        let run = AgentRun(folder: URL(fileURLWithPath: "/tmp/x"))
        run.ingest(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}"#)
        run.ingest(#"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#)
        #expect(run.state == .failed(AgentRun.signInMessage))
        // The raw error is replaced by a note on how to sign in.
        #expect(!run.messages.contains { $0.kind == .assistant })
        #expect(run.messages.last?.detail == "signin")

        let other = AgentRun(folder: URL(fileURLWithPath: "/tmp/y"))
        other.ingest(#"{"type":"result","is_error":true,"result":"Rate limited"}"#)
        #expect(other.state == .failed("Rate limited"))
    }
}

struct AgentPermissionTests {
    @Test func hookOutputAllowsAndDenies() throws {
        let allow = try JSONSerialization.jsonObject(with: AgentPermission.hookOutput(.allow)) as? [String: Any]
        let out = allow?["hookSpecificOutput"] as? [String: Any]
        #expect(out?["hookEventName"] as? String == "PermissionRequest")
        #expect((out?["decision"] as? [String: Any])?["behavior"] as? String == "allow")

        let deny = try JSONSerialization.jsonObject(with: AgentPermission.hookOutput(.deny("No"))) as? [String: Any]
        let d = (deny?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(d?["behavior"] as? String == "deny")
        #expect(d?["message"] as? String == "No")
        #expect(d?["interrupt"] as? Bool == false)
    }

    @Test func settingsAddOnlyThePermissionHook() throws {
        let json = try JSONSerialization.jsonObject(with: AgentPermission.settingsJSON(hookCommand: "'/x/orbit' hook permission")) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["PermissionRequest"])
        let entry = (hooks?["PermissionRequest"] as? [[String: Any]])?.first
        let hook = (entry?["hooks"] as? [[String: Any]])?.first
        #expect(hook?["command"] as? String == "'/x/orbit' hook permission")
        #expect(hook?["timeout"] as? Int == AgentPermission.hookTimeout)
        #expect(AgentPermission.answerTimeout < Double(AgentPermission.hookTimeout))
    }
}
