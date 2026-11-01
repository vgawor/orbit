import Foundation

/// Your open HubSpot tasks (assigned to you), next to the tasks on this Mac.
/// Uses a HubSpot private app token saved in the Keychain, and your HubSpot login email
/// to find which tasks are yours.
@MainActor
final class HubSpotTaskProvider: TaskProvider {
    let sourceID = "hubspot"
    let displayName = "HubSpot"

    static let tokenAccount = "hubspot"
    static let emailKey = "hubspot.email"
    static let portalKey = "hubspot.portalId"
    /// HubSpot's object type id for Projects.
    private static let projectType = "0-970"

    enum HubSpotError: LocalizedError {
        case notConnected, ownerNotFound(String), http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConnected: "HubSpot isn't connected."
            case .ownerNotFound(let email): "No HubSpot user with the email \(email)."
            case .http(let code, let message): code == 401 ? "HubSpot rejected the token." : "HubSpot (\(code)): \(message)"
            }
        }
    }

    private var ownerID: String?
    private var ownerEmail: String?
    /// Tasks you tick off in Orbit stay visible (ticked) for the rest of the day.
    private var recentlyCompleted: [String: TaskItem] = [:]

    static var isConfigured: Bool {
        Secrets.get(tokenAccount)?.isEmpty == false && !(UserDefaults.standard.string(forKey: emailKey) ?? "").isEmpty
    }

    // MARK: TaskProvider

    func fetch() async throws -> [TaskItem] {
        guard Self.isConfigured else { return [] }
        let owner = try await resolveOwner()
        let body: [String: Any] = [
            "filterGroups": [["filters": [
                ["propertyName": "hubspot_owner_id", "operator": "EQ", "value": owner],
                ["propertyName": "hs_task_status", "operator": "NEQ", "value": "COMPLETED"],
            ]]],
            "properties": ["hs_task_subject", "hs_task_status", "hs_timestamp", "hs_task_priority",
                           "hs_start_date", "hs_task_type", "hs_body_preview"],
            "sorts": [["propertyName": "hs_timestamp", "direction": "ASCENDING"]],
            "limit": 100,
        ]
        let json = try await request("POST", "/crm/v3/objects/tasks/search", body: body)
        let results = json["results"] as? [[String: Any]] ?? []
        var tasks = results.compactMap(Self.task(from:))
        await addProjectNames(to: &tasks)
        if let portal = await portalID() {
            for i in tasks.indices {
                tasks[i].link = URL(string: "https://app.hubspot.com/tasks/\(portal)/view/all/task/\(tasks[i].id)")
            }
        }
        // Keep ticked tasks around briefly so they don't vanish the moment you tick them.
        let open = Set(tasks.map(\.id))
        tasks += recentlyCompleted.values.filter { !open.contains($0.id) }
        recentlyCompleted = recentlyCompleted.filter { $0.value.completedAt.map(Calendar.current.isDateInToday) ?? false }
        return tasks
    }

    func add(_ item: TaskItem) async throws -> TaskItem {
        let owner = try await resolveOwner()
        let due = item.due ?? .now
        let body: [String: Any] = ["properties": [
            "hs_task_subject": item.title,
            "hs_task_status": "NOT_STARTED",
            "hs_timestamp": Self.iso.string(from: due),
            "hubspot_owner_id": owner,
        ]]
        let json = try await request("POST", "/crm/v3/objects/tasks", body: body)
        guard let created = Self.task(from: json) else { throw HubSpotError.http(0, "Unexpected answer") }
        var result = created
        result.dueHasTime = item.dueHasTime
        if item.due == nil { result.due = nil }
        return result
    }

    func update(_ item: TaskItem) async throws {
        let open = item.status.flatMap { $0 == "COMPLETED" ? nil : $0 } ?? "NOT_STARTED"
        var props: [String: Any] = ["hs_task_status": item.done ? "COMPLETED" : open, "hs_task_subject": item.title]
        if let due = item.due { props["hs_timestamp"] = Self.iso.string(from: due) }
        _ = try await request("PATCH", "/crm/v3/objects/tasks/\(item.id)", body: ["properties": props])
        if item.done { recentlyCompleted[item.id] = item } else { recentlyCompleted[item.id] = nil }
    }

    /// Deleting CRM records from the notch is too easy to do by accident, so it isn't offered.
    func delete(id: String) async throws {}

    // MARK: Full create (the task form)

    struct Draft {
        var title = ""
        var due: Date
        var type = "TODO"            // TODO, CALL, EMAIL
        var priority = "NONE"        // NONE, LOW, MEDIUM, HIGH
        var projectID: String?
        /// Minutes before the due time to remind you; nil for no reminder.
        var reminderMinutes: Int?
        var notes = ""
    }

    struct Project: Identifiable, Hashable {
        let id: String
        let name: String
        let mine: Bool
    }

    /// Creates a task with all its details, assigned to you, and links it to a project if one is chosen.
    func create(_ d: Draft) async throws -> TaskItem {
        let owner = try await resolveOwner()
        var props: [String: Any] = [
            "hs_task_subject": d.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "hs_task_status": "NOT_STARTED",
            "hs_timestamp": Self.iso.string(from: d.due),
            "hubspot_owner_id": owner,
            "hs_task_type": d.type,
        ]
        if d.priority != "NONE" { props["hs_task_priority"] = d.priority }
        let notes = d.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { props["hs_task_body"] = notes }
        if let m = d.reminderMinutes {
            let at = d.due.addingTimeInterval(-Double(m) * 60)
            props["hs_task_reminders"] = String(Int64(at.timeIntervalSince1970 * 1000))
        }
        let json = try await request("POST", "/crm/v3/objects/tasks", body: ["properties": props])
        guard var task = Self.task(from: json) else { throw HubSpotError.http(0, "Unexpected answer") }
        task.dueHasTime = true
        task.status = "NOT_STARTED"
        task.type = d.type
        task.priority = d.priority
        task.notes = notes.isEmpty ? nil : notes
        if let pid = d.projectID {
            // "default" lets HubSpot pick the standard task↔project link.
            _ = try await request("PUT", "/crm/v4/objects/tasks/\(task.id)/associations/default/\(Self.projectType)/\(pid)", body: nil)
            task.project = projectNames[pid]
        }
        if let portal = await portalID() {
            task.link = URL(string: "https://app.hubspot.com/tasks/\(portal)/view/all/task/\(task.id)")
        }
        return task
    }

    /// Projects you can link a task to: yours first, then the rest, most recently changed first.
    func projects() async throws -> [Project] {
        let owner = try await resolveOwner()
        let body: [String: Any] = [
            "properties": ["hs_name", "hubspot_owner_id"],
            "sorts": [["propertyName": "hs_lastmodifieddate", "direction": "DESCENDING"]],
            "limit": 100,
        ]
        let json = try await request("POST", "/crm/v3/objects/\(Self.projectType)/search", body: body)
        let list: [Project] = (json["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String, let props = r["properties"] as? [String: Any],
                  let name = props["hs_name"] as? String else { return nil }
            projectNames[id] = name
            return Project(id: id, name: name, mine: (props["hubspot_owner_id"] as? String) == owner)
        }
        return list.filter(\.mine) + list.filter { !$0.mine }
    }

    // MARK: Connection test (Settings)

    /// Returns how many open tasks you have, or throws a readable error.
    func test() async throws -> Int {
        ownerID = nil
        return try await fetch().filter { !$0.done }.count
    }

    // MARK: Projects and links (best effort: skipped if the token can't read projects)

    private var projectNames: [String: String] = [:]

    /// Tags tasks that belong to a HubSpot project with the project's name.
    private func addProjectNames(to tasks: inout [TaskItem]) async {
        guard !tasks.isEmpty else { return }
        let inputs = tasks.map { ["id": $0.id] }
        guard let assoc = try? await request("POST", "/crm/v4/associations/tasks/\(Self.projectType)/batch/read",
                                              body: ["inputs": inputs]) else { return }
        var projectFor: [String: String] = [:]
        for r in assoc["results"] as? [[String: Any]] ?? [] {
            guard let from = (r["from"] as? [String: Any])?["id"].map({ "\($0)" }),
                  let to = (r["to"] as? [[String: Any]])?.first?["toObjectId"] else { continue }
            projectFor[from] = "\(to)"
        }
        let missing = Set(projectFor.values).subtracting(projectNames.keys)
        if !missing.isEmpty, let read = try? await request(
            "POST", "/crm/v3/objects/\(Self.projectType)/batch/read",
            body: ["properties": ["hs_name"], "inputs": missing.map { ["id": $0] }]) {
            for p in read["results"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String, let name = (p["properties"] as? [String: Any])?["hs_name"] as? String {
                    projectNames[id] = name
                }
            }
        }
        for i in tasks.indices {
            if let pid = projectFor[tasks[i].id] { tasks[i].project = projectNames[pid] }
        }
    }

    /// Your HubSpot account number, needed for "Open in HubSpot" links.
    private func portalID() async -> String? {
        if let saved = UserDefaults.standard.string(forKey: Self.portalKey), !saved.isEmpty { return saved }
        guard let info = try? await request("GET", "/account-info/v3/details", body: nil),
              let id = info["portalId"] else { return nil }
        UserDefaults.standard.set("\(id)", forKey: Self.portalKey)
        return "\(id)"
    }

    // MARK: Helpers

    func resolveOwner() async throws -> String {
        guard let email = UserDefaults.standard.string(forKey: Self.emailKey)?.trimmingCharacters(in: .whitespaces),
              !email.isEmpty else { throw HubSpotError.notConnected }
        if let ownerID, ownerEmail == email { return ownerID }
        let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let json = try await request("GET", "/crm/v3/owners/?email=\(encoded)&limit=1", body: nil)
        guard let first = (json["results"] as? [[String: Any]])?.first, let id = first["id"] else {
            throw HubSpotError.ownerNotFound(email)
        }
        ownerID = "\(id)"
        ownerEmail = email
        return "\(id)"
    }

    func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let token = Secrets.get(Self.tokenAccount), !token.isEmpty else { throw HubSpotError.notConnected }
        var req = URLRequest(url: URL(string: "https://api.hubapi.com" + path)!, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else { throw HubSpotError.http(code, Self.explain(json)) }
        return json
    }

    /// Turns HubSpot's error body into a short message, naming missing permissions when that's the cause.
    private static func explain(_ json: [String: Any]) -> String {
        if let ctx = json["context"] as? [String: Any],
           let scopes = (ctx["requiredGranularScopes"] ?? ctx["requiredScopes"]) as? [String], !scopes.isEmpty {
            return "the token is missing permission: \(scopes.joined(separator: ", "))"
        }
        if let errors = json["errors"] as? [[String: Any]], let ctx = errors.first?["context"] as? [String: Any],
           let scopes = (ctx["requiredGranularScopes"] ?? ctx["requiredScopes"]) as? [String], !scopes.isEmpty {
            return "the token is missing permission: \(scopes.joined(separator: ", "))"
        }
        return json["message"] as? String ?? "unknown error"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s) ?? Double(s).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    static func task(from json: [String: Any]) -> TaskItem? {
        guard let id = json["id"] as? String, let props = json["properties"] as? [String: Any] else { return nil }
        let due = parseDate(props["hs_timestamp"] as? String)
        let comps = due.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        // HubSpot always stores a time; treat midnight as "just a day".
        let hasTime = comps.map { !($0.hour == 0 && $0.minute == 0) } ?? false
        func text(_ key: String) -> String? {
            (props[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        return TaskItem(id: id, title: text("hs_task_subject") ?? "Untitled task",
                        done: text("hs_task_status") == "COMPLETED",
                        due: due, dueHasTime: hasTime, source: "hubspot",
                        start: parseDate(text("hs_start_date")), status: text("hs_task_status"),
                        priority: text("hs_task_priority"), type: text("hs_task_type"), notes: text("hs_body_preview"))
    }
}


// MARK: - Contacts, companies, deals and notes (for meeting prep and Smart Ask)

extension HubSpotTaskProvider {
    /// Looks up contacts by email and returns a readable summary: who they are, their company,
    /// open deals and the latest notes. Parts the token isn't allowed to read are skipped and named.
    func lookupContacts(emails: [String]) async -> String {
        guard Self.isConfigured else { return "HubSpot isn't connected." }
        let emails = Array(Set(emails.map { $0.lowercased() })).prefix(20)
        guard !emails.isEmpty else { return "No email addresses to look up." }
        var lines: [String] = []
        var skipped: [String] = []

        guard let found = try? await request("POST", "/crm/v3/objects/contacts/search", body: [
            "filterGroups": [["filters": [["propertyName": "email", "operator": "IN", "values": Array(emails)]]]],
            "properties": ["firstname", "lastname", "email", "jobtitle", "company", "notes_last_contacted", "hs_lead_status"],
            "limit": 20,
        ]), let contacts = found["results"] as? [[String: Any]] else {
            return "Couldn't search HubSpot contacts (the token may lack contacts read access)."
        }
        if contacts.isEmpty { return "None of these people are in HubSpot: \(emails.joined(separator: ", "))." }
        let ids = contacts.compactMap { $0["id"] as? String }

        func associated(_ to: String) async -> [String: [String]]? {
            guard let r = try? await request("POST", "/crm/v4/associations/contacts/\(to)/batch/read",
                                             body: ["inputs": ids.map { ["id": $0] }]) else { return nil }
            var map: [String: [String]] = [:]
            for row in r["results"] as? [[String: Any]] ?? [] {
                guard let from = (row["from"] as? [String: Any])?["id"].map({ "\($0)" }) else { continue }
                map[from] = (row["to"] as? [[String: Any]] ?? []).compactMap { $0["toObjectId"].map { "\($0)" } }
            }
            return map
        }
        func read(_ type: String, _ ids: [String], _ props: [String]) async -> [String: [String: Any]]? {
            guard !ids.isEmpty else { return [:] }
            guard let r = try? await request("POST", "/crm/v3/objects/\(type)/batch/read",
                                             body: ["properties": props, "inputs": Array(Set(ids)).map { ["id": $0] }]) else { return nil }
            var map: [String: [String: Any]] = [:]
            for row in r["results"] as? [[String: Any]] ?? [] {
                if let id = row["id"] as? String { map[id] = row["properties"] as? [String: Any] ?? [:] }
            }
            return map
        }

        let companyLinks = await associated("companies")
        let dealLinks = await associated("deals")
        let noteLinks = await associated("notes")
        let companies = await read("companies", companyLinks?.values.flatMap { $0 } ?? [], ["name", "domain", "industry", "city"])
        let deals = await read("deals", dealLinks?.values.flatMap { $0 } ?? [], ["dealname", "amount", "dealstage", "closedate", "hs_is_closed", "hubspot_owner_id"])
        let me = (try? await resolveOwner()) ?? ""
        let notes = await read("notes", Array((noteLinks?.values.flatMap { $0 } ?? []).suffix(30)), ["hs_note_body", "hs_timestamp"])
        if companyLinks == nil || companies == nil { skipped.append("companies") }
        if dealLinks == nil || deals == nil { skipped.append("deals") }
        if noteLinks == nil || notes == nil { skipped.append("notes") }

        func text(_ any: Any?) -> String { (any as? String).map { $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) } ?? "" }

        for c in contacts {
            guard let id = c["id"] as? String, let p = c["properties"] as? [String: Any] else { continue }
            let name = [text(p["firstname"]), text(p["lastname"])].filter { !$0.isEmpty }.joined(separator: " ")
            var line = "• \(name.isEmpty ? text(p["email"]) : name) <\(text(p["email"]))>"
            if !text(p["jobtitle"]).isEmpty { line += ", \(text(p["jobtitle"]))" }
            lines.append(line)
            for cid in companyLinks?[id] ?? [] {
                if let co = companies?[cid] { lines.append("  Company: \(text(co["name"])) \(text(co["industry"])) \(text(co["city"]))".trimmingCharacters(in: .whitespaces)) }
            }
            for did in dealLinks?[id] ?? [] {
                guard let d = deals?[did] else { continue }
                let closed = text(d["hs_is_closed"]) == "true" ? "closed" : "open"
                let whose = Self.isOwned(["properties": d], by: me) ? "" : ", not yours: someone else owns it"
                lines.append("  Deal (\(closed)\(whose)): \(text(d["dealname"])) · amount \(text(d["amount"])) · stage \(text(d["dealstage"])) · close \(text(d["closedate"]).prefix(10))")
            }
            let ns = (noteLinks?[id] ?? []).compactMap { notes?[$0] }
                .sorted { text($0["hs_timestamp"]) > text($1["hs_timestamp"]) }.prefix(3)
            for n in ns {
                lines.append("  Note \(text(n["hs_timestamp"]).prefix(10)): \(text(n["hs_note_body"]).prefix(300))")
            }
            if !text(p["notes_last_contacted"]).isEmpty { lines.append("  Last contacted: \(text(p["notes_last_contacted"]).prefix(10))") }
        }
        if !skipped.isEmpty { lines.append("(Couldn't read \(skipped.joined(separator: ", ")) — the token may lack those permissions.)") }
        return lines.joined(separator: "\n")
    }
}
