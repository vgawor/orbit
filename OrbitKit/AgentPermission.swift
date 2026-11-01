import Foundation

/// Approvals for Claude Code sessions that Orbit starts.
///
/// Orbit launches `claude -p` with an extra settings file that adds a PermissionRequest hook:
/// `orbit hook permission`. Claude Code runs that hook whenever it wants to do something that
/// needs your OK (edit a file, run a command). The hook asks the app, the app shows Allow/Deny
/// in the notch, and the hook prints the answer back to Claude Code. No answer means no.
public enum AgentPermission {
    /// Environment variable that tells the hook which Orbit run it belongs to.
    public static let runEnv = "ORBIT_RUN_ID"
    /// How long Claude Code waits for the hook (seconds). The app answers "deny" a bit before this.
    public static let hookTimeout = 900
    /// How long the app waits for your click before denying.
    public static let answerTimeout: TimeInterval = 840
    /// For terminal sessions: how long the notch waits before handing the question back to the terminal.
    public static let terminalAnswerTimeout: TimeInterval = 120

    public struct Decision: Codable, Equatable, Sendable {
        public var behavior: String          // "allow" or "deny"
        public var message: String?
        public init(behavior: String, message: String? = nil) {
            self.behavior = behavior
            self.message = message
        }
        public static let allow = Decision(behavior: "allow")
        public static func deny(_ why: String) -> Decision { Decision(behavior: "deny", message: why) }
        /// No decision: Claude Code asks in the terminal as usual.
        public static let askInTerminal = Decision(behavior: "ask")
    }

    /// What the hook prints for Claude Code.
    public static func hookOutput(_ decision: Decision) -> Data {
        var d: [String: Any] = ["behavior": decision.behavior]
        if decision.behavior == "deny" {
            d["message"] = decision.message ?? "Denied in Orbit"
            d["interrupt"] = false
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    /// The settings file Orbit passes to `claude --settings`. Only runs Orbit starts get this hook.
    public static func settingsJSON(hookCommand: String) -> Data {
        let settings: [String: Any] = [
            "hooks": [
                "PermissionRequest": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": hookCommand, "timeout": hookTimeout]],
                ]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
