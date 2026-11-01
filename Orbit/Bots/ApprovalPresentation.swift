import Foundation

/// How a bot's request looks in the notch: a sentence, the button that carries it out, and the
/// fields the user can edit before approving. Pure, so it's easy to test.
struct ApprovalPresentation: Equatable {
    struct Field: Equatable, Identifiable {
        let key: String
        let label: String
        var value: String
        var multiline = false
        /// Comma-separated list (email recipients).
        var isList = false
        var id: String { key }
    }

    let title: String
    let action: String
    var fields: [Field]

    init(tool: String, input: [String: Any]) {
        func v(_ key: String) -> String { Self.text(input[key]) }
        switch tool {
        case "draft_email":
            let to = v("to")
            title = "Draft an email to \(to.isEmpty ? "someone" : to)"
            action = "Open draft"
            fields = [Field(key: "to", label: "To", value: to, isList: true),
                      Field(key: "subject", label: "Subject", value: v("subject")),
                      Field(key: "body", label: "Message", value: v("body"), multiline: true)]
        case "create_task":
            let place = v("target") == "hubspot" ? "in HubSpot" : "on your Mac"
            title = "Create a task \(place): “\(v("title"))”"
            action = "Create task"
            fields = [Field(key: "title", label: "Task", value: v("title")),
                      Field(key: "due", label: "Due", value: v("due")),
                      Field(key: "notes", label: "Notes", value: v("notes"), multiline: true)]
        case "update_task":
            title = "Update a task" + (v("title").isEmpty ? "" : ": “\(v("title"))”")
            action = "Update task"
            fields = [Field(key: "title", label: "Title", value: v("title")),
                      Field(key: "due", label: "Due", value: v("due")),
                      Field(key: "status", label: "Status", value: v("status"))]
        case "add_note":
            title = "Save a note in Orbit"
            action = "Save note"
            fields = [Field(key: "text", label: "Note", value: v("text"), multiline: true)]
        case "hubspot_log_note":
            title = "Log a note on deal \(v("deal_id"))"
            action = "Log note"
            fields = [Field(key: "body", label: "Note", value: v("body"), multiline: true)]
        case "hubspot_update_deal":
            let parts = [("dealstage", "stage"), ("closedate", "close date"), ("amount", "amount")]
                .filter { !v($0.0).isEmpty }.map { "\($0.1) → \(v($0.0))" }
            title = "Update deal \(v("deal_id")): \(parts.joined(separator: ", "))"
            action = "Update deal"
            fields = [Field(key: "dealstage", label: "Stage", value: v("dealstage")),
                      Field(key: "closedate", label: "Close date", value: v("closedate")),
                      Field(key: "amount", label: "Amount", value: v("amount"))]
        case "hand_off":
            title = "Hand to \(v("to")): \(v("task"))"
            action = "Hand over"
            fields = [Field(key: "task", label: "Task", value: v("task"), multiline: true),
                      Field(key: "context", label: "Context", value: v("context"), multiline: true)]
        default:
            title = "Use \(tool)"
            action = "Approve"
            fields = []
        }
    }

    /// The edited fields as tool input: lists become arrays, untouched empty fields are left out.
    func edits(from original: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for f in fields {
            let before = Self.text(original[f.key])
            guard f.value != before else { continue }
            if f.isList {
                out[f.key] = f.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                out[f.key] = f.value
            }
        }
        return out
    }

    /// Any input value as plain text (arrays joined with commas).
    static func text(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let a as [Any]: return a.map { text($0) }.joined(separator: ", ")
        case let n as NSNumber: return n.stringValue
        case nil: return ""
        default: return "\(any!)"
        }
    }
}
