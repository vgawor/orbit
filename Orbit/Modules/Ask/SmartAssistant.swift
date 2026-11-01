import AppKit
import SwiftUI

/// Smart Ask: Claude with Orbit's own actions as tools. Understands plain sentences
/// ("move Skapa offert to Monday and remind me 30 min before") and acts on them.
/// Anything that changes HubSpot waits for your OK in the panel first.
/// Also writes the morning brief and meeting prep.
@MainActor
@Observable
final class SmartAssistant: NotchModule {
    let id = "smart"
    let title = "Smart Ask"
    let symbol = "sparkles"
    var showsTab: Bool { false }
    var panel: AnyView { AnyView(EmptyView()) }

    struct Turn: Identifiable {
        enum Kind { case user, assistant, action, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    private(set) var turns: [Turn] = []
    private(set) var busy = false
    private(set) var pending: Confirmation?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    /// The exact conversation sent to Claude (append-only, so cached and valid across turns).
    private var history: [[String: Any]] = []

    // Morning brief
    private(set) var brief: String? = UserDefaults.standard.string(forKey: "brief.text")
    private(set) var briefDay: String? = UserDefaults.standard.string(forKey: "brief.day")
    private(set) var briefLoading = false
    private(set) var briefError: String?

    private let music: MusicModule
    private let meetings: MeetingsModule
    private let tasks: TasksModule
    private let focus: FocusModule
    private let notes: NotesModule
    private let agents: () -> AgentsModule?
    private let openPanel: @MainActor (String) -> Void
    private let setPresenting: @MainActor (Bool) -> Void

    init(music: MusicModule, meetings: MeetingsModule, tasks: TasksModule, focus: FocusModule, notes: NotesModule,
         agents: @escaping () -> AgentsModule?, openPanel: @escaping @MainActor (String) -> Void,
         setPresenting: @escaping @MainActor (Bool) -> Void) {
        self.music = music; self.meetings = meetings; self.tasks = tasks; self.focus = focus; self.notes = notes
        self.agents = agents; self.openPanel = openPanel; self.setPresenting = setPresenting
        self.orbitTools = OrbitTools(music: music, meetings: meetings, tasks: tasks, focus: focus, notes: notes, agents: agents)
    }

    /// Read-only views shared with Bots.
    let orbitTools: OrbitTools

    var isConfigured: Bool { ClaudeAPI.isConfigured }

    // MARK: Conversation

    func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        turns.append(Turn(kind: .user, text: q))
        history.append(["role": "user", "content": [["type": "text", "text": "[Now: \(Self.now())]\n\(q)"]]])
        Task { await runLoop() }
    }

    /// Start over (Esc or "New").
    func reset() {
        resolve(false)
        turns = []
        history = []
        busy = false
    }

    func resolve(_ ok: Bool) {
        pending = nil
        confirmContinuation?.resume(returning: ok)
        confirmContinuation = nil
    }

    private func confirm(_ title: String, _ detail: String) async -> Bool {
        await withCheckedContinuation { cont in
            confirmContinuation = cont
            pending = Confirmation(title: title, detail: detail)
            openPanel("ask")
        }
    }

    private func runLoop() async {
        busy = true
        defer { busy = false }
        for _ in 0..<8 {
            do {
                let response = try await ClaudeAPI.send(system: Self.system, messages: history, tools: Self.tools)
                let content = response["content"] as? [[String: Any]] ?? []
                history.append(["role": "assistant", "content": content])
                let stop = response["stop_reason"] as? String
                if stop == "refusal" {
                    turns.append(Turn(kind: .error, text: "Claude declined this one. Try wording it differently."))
                    return
                }
                let text = ClaudeAPI.text(content)
                if !text.isEmpty { turns.append(Turn(kind: .assistant, text: text)) }
                guard stop == "tool_use" else { return }

                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (out, isError) = await runTool(name, input)
                    results.append(["type": "tool_result", "tool_use_id": id, "content": out, "is_error": isError])
                }
                // All results in one message, so Claude keeps using tools in parallel.
                history.append(["role": "user", "content": results])
            } catch {
                turns.append(Turn(kind: .error, text: error.localizedDescription))
                // Keep the history valid for a retry: drop a trailing user turn that never got an answer.
                return
            }
        }
    }

    // MARK: Tools

    private static var system: String { UserProfile.fill(systemTemplate) }
    private static let systemTemplate = """
    You are Orbit, a small assistant that lives in the MacBook notch of {{fullName}}. {{intro}}
    You can see and act on their calendar, tasks (on this Mac and in HubSpot), focus timer, music (Spotify/Music), notes and apps, using the tools.
    Each message starts with the current date and time.

    How to work:
    - Act with the tools instead of describing what you would do. Call get_overview first when you need to know what's going on.
    - Resolve relative dates ("Monday", "tomorrow at 9", "next week") from the current time; times are local (Europe/Stockholm unless told otherwise).
    - Changes in HubSpot are confirmed by {{name}} in the app automatically before they run; don't ask for confirmation in text, just call the tool.
    - If a request is ambiguous (e.g. several tasks match), ask one short question.
    - Reply in the user's language (Swedish or English), in 1–3 short sentences. Plain text; a short bullet list only when listing several things.
    - When nothing needs doing, just answer the question.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    private static let tools: [[String: Any]] = [
        tool("get_overview", "What's going on: current time, upcoming meetings (36 h), open tasks with ids, due dates, source and project, focus timer, music and agent sessions.", [:]),
        tool("create_task", "Create a task. target 'hubspot' creates it in HubSpot assigned to the user (asks them to confirm); 'mac' keeps it on this Mac.", [
            "title": ["type": "string"],
            "due": ["type": "string", "description": "ISO 8601 local date or date-time, e.g. 2026-10-30 or 2026-10-30T08:00. Omit for no date (HubSpot then uses 3 workdays at 08:00)."],
            "target": ["type": "string", "enum": ["mac", "hubspot"]],
            "project": ["type": "string", "description": "HubSpot project name to link it to (optional)."],
            "priority": ["type": "string", "enum": ["NONE", "LOW", "MEDIUM", "HIGH"]],
            "type": ["type": "string", "enum": ["TODO", "CALL", "EMAIL"]],
            "notes": ["type": "string"],
            "reminder_minutes": ["type": "integer", "description": "Remind this many minutes before the due time (HubSpot only)."],
        ], required: ["title", "target"]),
        tool("update_task", "Change a task's title, due date or status. Use the id from get_overview. HubSpot changes are confirmed by the user first.", [
            "task_id": ["type": "string"],
            "title": ["type": "string"],
            "due": ["type": "string", "description": "ISO 8601 local date or date-time."],
            "status": ["type": "string", "enum": ["NOT_STARTED", "IN_PROGRESS", "WAITING", "DEFERRED", "COMPLETED"]],
        ], required: ["task_id"]),
        tool("start_timer", "Start a countdown timer (several can run at once). No music.", [
            "minutes": ["type": "integer", "minimum": 1, "maximum": 1440],
            "label": ["type": "string", "description": "Short name, e.g. 'Tea' (optional)."],
        ], required: ["minutes"]),
        tool("start_focus", "Start a focus session of N minutes. Plays the focus playlist if one is set.", [
            "minutes": ["type": "integer", "minimum": 1, "maximum": 180],
        ], required: ["minutes"]),
        tool("music", "Control the music player.", [
            "action": ["type": "string", "enum": ["play_pause", "next", "previous"]],
        ], required: ["action"]),
        tool("join_meeting", "Join a meeting's video call (Zoom, Teams, Meet, Webex). Without a title, joins the next one with a link.", [
            "title": ["type": "string", "description": "Part of the meeting title (optional)."],
        ]),
        tool("add_note", "Save a note in Orbit's Notes.", ["text": ["type": "string"]], required: ["text"]),
        tool("open_app", "Open a Mac app by name.", ["name": ["type": "string"]], required: ["name"]),
        tool("set_presenting", "Turn Presenting mode on or off (hides notch content and pop-ups while sharing the screen).", [
            "on": ["type": "boolean"],
        ], required: ["on"]),
        tool("lookup_contacts", "Look people up in HubSpot by email: role, company, open deals and latest notes.", [
            "emails": ["type": "array", "items": ["type": "string"]],
        ], required: ["emails"]),
    ]

    private func runTool(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
        switch name {
        case "get_overview":
            return (overview(), false)

        case "create_task":
            guard let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
                return ("Missing title.", true)
            }
            let (due, hasTime) = Self.parseDate(input["due"] as? String)
            if (input["target"] as? String) == "hubspot" {
                guard let hubspot = tasks.hubspot, HubSpotTaskProvider.isConfigured else { return ("HubSpot isn't connected.", true) }
                var draft = HubSpotTaskProvider.Draft(due: due.map { hasTime ? $0 : HubSpotTaskForm.at8($0) } ?? HubSpotTaskForm.businessDays(3))
                draft.title = title
                draft.priority = input["priority"] as? String ?? "NONE"
                draft.type = input["type"] as? String ?? "TODO"
                draft.notes = input["notes"] as? String ?? ""
                draft.reminderMinutes = input["reminder_minutes"] as? Int
                var projectName: String?
                if let wanted = (input["project"] as? String)?.lowercased(), !wanted.isEmpty {
                    let projects = (try? await hubspot.projects()) ?? []
                    if let p = projects.first(where: { $0.name.lowercased() == wanted }) ?? projects.first(where: { $0.name.lowercased().contains(wanted) }) {
                        draft.projectID = p.id
                        projectName = p.name
                    } else {
                        return ("No HubSpot project matches '\(wanted)'. Projects: \(projects.map(\.name).joined(separator: ", ")).", true)
                    }
                }
                let detail = [Self.describe(draft.due, hasTime: true), projectName, draft.priority != "NONE" ? "\(draft.priority.capitalized) priority" : nil,
                              draft.reminderMinutes.map { "remind \($0) min before" }].compactMap { $0 }.joined(separator: " · ")
                guard await confirm("Create HubSpot task “\(title)”?", detail) else { return ("\(UserProfile.firstName) declined; nothing was created.", false) }
                do {
                    let created = try await hubspot.create(draft)
                    await tasks.reload()
                    turns.append(Turn(kind: .action, text: "Created HubSpot task “\(created.title)”"))
                    return ("Created HubSpot task id \(created.id).", false)
                } catch {
                    return ("HubSpot error: \(error.localizedDescription)", true)
                }
            }
            tasks.addLocal(title: title, due: due, hasTime: hasTime)
            turns.append(Turn(kind: .action, text: "Added “\(title)”" + (due.map { " · \(Self.describe($0, hasTime: hasTime))" } ?? "")))
            return ("Added on this Mac.", false)

        case "update_task":
            guard let id = input["task_id"] as? String, var item = tasks.items.first(where: { $0.id == id }) else {
                return ("No task with that id. Call get_overview for ids.", true)
            }
            var changes: [String] = []
            if let t = input["title"] as? String, !t.isEmpty, t != item.title { item.title = t; changes.append("title “\(t)”") }
            if let d = input["due"] as? String {
                let (due, hasTime) = Self.parseDate(d)
                if let due {
                    item.due = hasTime || item.source != "hubspot" ? due : HubSpotTaskForm.at8(due)
                    item.dueHasTime = hasTime || item.source == "hubspot"
                    changes.append("due \(Self.describe(item.due!, hasTime: item.dueHasTime))")
                }
            }
            if let s = input["status"] as? String {
                item.status = s
                item.done = s == "COMPLETED"
                item.completedAt = item.done ? .now : nil
                changes.append(s == "COMPLETED" ? "mark done" : "status \(s.replacingOccurrences(of: "_", with: " ").lowercased())")
            }
            guard !changes.isEmpty else { return ("Nothing to change.", false) }
            if item.source == "hubspot" {
                guard await confirm("Update “\(item.title)” in HubSpot?", changes.joined(separator: " · ")) else {
                    return ("\(UserProfile.firstName) declined; nothing changed.", false)
                }
            }
            do {
                try await tasks.apply(item)
                turns.append(Turn(kind: .action, text: "Updated “\(item.title)”: \(changes.joined(separator: ", "))"))
                return ("Updated.", false)
            } catch {
                return ("Couldn't update: \(error.localizedDescription)", true)
            }

        case "start_focus":
            let m = min(max(input["minutes"] as? Int ?? 25, 1), 180)
            focus.startFocus(minutes: m)
            turns.append(Turn(kind: .action, text: "Focus started · \(m) min" + (focus.playlist.map { " · \($0.name)" } ?? "")))
            return ("Focus session running for \(m) minutes.", false)

        case "start_timer":
            let m = min(max(input["minutes"] as? Int ?? 5, 1), 1440)
            let label = input["label"] as? String
            focus.startTimer(m, label: label)
            turns.append(Turn(kind: .action, text: "Timer started · \(label.map { "\($0) · " } ?? "")\(m) min"))
            return ("Timer running for \(m) minutes.", false)

        case "music":
            switch input["action"] as? String {
            case "next": music.send(.next)
            case "previous": music.send(.previous)
            default: music.send(.playPause)
            }
            return ("Done.", false)

        case "join_meeting":
            let wanted = (input["title"] as? String)?.lowercased() ?? ""
            let candidates = meetings.meetings.filter { $0.link != nil }
            guard let m = wanted.isEmpty ? candidates.first : candidates.first(where: { $0.title.lowercased().contains(wanted) }) else {
                return ("No upcoming meeting with a video link\(wanted.isEmpty ? "" : " matching '\(wanted)'").", true)
            }
            meetings.join(m)
            turns.append(Turn(kind: .action, text: "Joining \(m.title) in \(m.link?.provider.rawValue ?? "the browser")"))
            return ("Opened the call for \(m.title).", false)

        case "add_note":
            guard let text = input["text"] as? String, !text.isEmpty else { return ("Empty note.", true) }
            notes.add()
            if let id = notes.selectedID { notes.update(id, body: text) }
            turns.append(Turn(kind: .action, text: "Saved a note"))
            return ("Saved.", false)

        case "open_app":
            let name = input["name"] as? String ?? ""
            return AskActions.launchApp(name) ? ("Opened \(name).", false) : ("Couldn't find an app called \(name).", true)

        case "set_presenting":
            let on = input["on"] as? Bool ?? true
            setPresenting(on)
            return ("Presenting is \(on ? "on" : "off").", false)

        case "lookup_contacts":
            guard let hubspot = tasks.hubspot else { return ("HubSpot isn't connected.", true) }
            let emails = input["emails"] as? [String] ?? []
            return (await hubspot.lookupContacts(emails: emails), false)

        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Snapshot of the user's state for Claude.
    private func overview() -> String { orbitTools.overview() }

    // MARK: Morning brief

    static func todayKey() -> String { Date.now.formatted(.iso8601.year().month().day()) }

    var briefIsFresh: Bool { briefDay == Self.todayKey() && brief != nil }

    /// Writes today's brief once (after 05:00), or again when asked.
    func loadBrief(force: Bool = false) {
        guard isConfigured, !briefLoading else { return }
        guard force || (!briefIsFresh && Calendar.current.component(.hour, from: .now) >= 5) else { return }
        briefLoading = true
        briefError = nil
        Task {
            defer { briefLoading = false }
            do {
                let r = try await ClaudeAPI.send(system: Self.briefSystem, messages: [
                    ["role": "user", "content": [["type": "text", "text": overview()]]],
                ])
                let text = ClaudeAPI.text(r["content"] as? [[String: Any]] ?? [])
                guard !text.isEmpty else { return }
                brief = text
                briefDay = Self.todayKey()
                UserDefaults.standard.set(text, forKey: "brief.text")
                UserDefaults.standard.set(briefDay, forKey: "brief.day")
            } catch {
                briefError = error.localizedDescription
            }
        }
    }

    private static var briefSystem: String { UserProfile.fill(briefTemplate) }
    private static let briefTemplate = """
    You write {{fullName}}'s morning brief for the notch of their Mac. Use only the data given.
    Format: at most 4 short bullet lines ("• "), most important first: the first meeting and anything to prepare,
    overdue or due-today tasks, what's due later this week, and anything an agent finished or needs.
    Then one short encouraging closing line. Match Swedish or English to the task and meeting names. No headings.
    """

    // MARK: Meeting prep

    /// Looks the attendees up in HubSpot and asks Claude for a short prep, shown in Ask.
    func prepare(_ m: Meeting) {
        guard isConfigured, !busy else { openPanel("ask"); return }
        openPanel("ask")
        let title = m.title.trimmingCharacters(in: .whitespaces)
        turns.append(Turn(kind: .user, text: "Prep for \(title)"))
        busy = true
        Task {
            let crm: String
            if let hubspot = tasks.hubspot, !m.attendeeEmails.isEmpty {
                crm = await hubspot.lookupContacts(emails: m.attendeeEmails)
            } else {
                crm = m.attendeeEmails.isEmpty ? "No other attendees on the invite." : "HubSpot isn't connected."
            }
            let openTasks = tasks.items.filter { !$0.done }.map { "“\($0.title)”\($0.project.map { " (\($0))" } ?? "")" }.prefix(20).joined(separator: ", ")
            let prompt = """
            [Now: \(Self.now())]
            Prepare me for this meeting. Give: who's attending (role, company), the relationship so far (deals, last notes),
            open tasks that relate to them, and 2–3 suggested talking points or questions. Keep it short, bullets.

            Meeting: \(title) · \(m.timeRange) · \(m.link?.provider.rawValue ?? "no video link")
            Attendees: \(m.attendeeEmails.joined(separator: ", "))
            HubSpot:
            \(crm)
            My open tasks: \(openTasks)
            """
            history.append(["role": "user", "content": [["type": "text", "text": prompt]]])
            busy = false
            await runLoop()
        }
    }

    // MARK: Helpers

    static func now() -> String { OrbitTools.now() }

    static func iso(_ d: Date) -> String { OrbitTools.iso(d) }

    /// "2026-10-30" → (date at local midnight, false); "2026-10-30T08:00" → (that time, true).
    static func parseDate(_ s: String?) -> (Date?, Bool) {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return (nil, false) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            f.dateFormat = format
            if let d = f.date(from: String(s.prefix(format.replacingOccurrences(of: "'", with: "").count))) {
                return (hasTime ? d : Calendar.current.startOfDay(for: d), hasTime)
            }
        }
        if let d = ISO8601DateFormatter().date(from: s) { return (d, true) }
        return (nil, false)
    }

    static func describe(_ d: Date, hasTime: Bool) -> String {
        hasTime ? d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Views

/// The Smart Ask conversation inside the Ask tab.
struct SmartConversation: View {
    let smart: SmartAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Orbit thinks (a moon circles its ring) while Claude works, and waits wide-eyed for a yes/no.
                OrbitView(size: 26, mood: smart.pending != nil ? .wide : .normal,
                          motion: smart.busy ? .thinking : smart.pending != nil ? .glow : .idle)
                Text("Orbit · Claude").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tokens.secondary)
                Spacer()
                Button("New") { smart.reset() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(smart.turns) { turn in row(turn).id(turn.id) }
                        if let p = smart.pending {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.title).font(.system(size: 12.5, weight: .semibold))
                                if !p.detail.isEmpty {
                                    Text(p.detail).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                                }
                                HStack(spacing: 6) {
                                    PillButton(title: "Confirm", fill: Color(red: 1, green: 0.48, blue: 0.35)) { smart.resolve(true) }
                                    PillButton(title: "Cancel", fill: Tokens.surface2) { smart.resolve(false) }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(red: 1, green: 0.48, blue: 0.35).opacity(0.5)))
                            .id("pending")
                        }
                        if smart.busy && smart.pending == nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            }
                            .id("busy")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: smart.turns.count) { _, _ in withAnimation { proxy.scrollTo(smart.turns.last?.id) } }
                .onChange(of: smart.pending?.id) { _, _ in withAnimation { proxy.scrollTo("pending") } }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
    }

    @ViewBuilder private func row(_ t: SmartAssistant.Turn) -> some View {
        switch t.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(t.text).font(.system(size: 12.5)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Tokens.surface2))
            }
        case .assistant:
            Text(LocalizedStringKey(t.text)).font(.system(size: 12.5)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            Label(t.text, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.live)
        case .error:
            Label(t.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Tokens.error)
        }
    }
}

/// Home feed widget: today's brief, written by Claude.
struct BriefWidget: View {
    let smart: SmartAssistant

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                    Text("TODAY").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Tokens.secondary)
                    Spacer()
                    if smart.briefLoading {
                        ProgressView().controlSize(.mini)
                    } else if smart.isConfigured {
                        Button { smart.loadBrief(force: true) } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.faint)
                        }
                        .buttonStyle(.plain).help("Write a new brief")
                    }
                }
                if !smart.isConfigured {
                    Text("Add a Claude API key in Settings → Accounts to get a short brief of your day here.")
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                } else if let brief = smart.brief, smart.briefIsFresh || !smart.briefLoading {
                    Text(LocalizedStringKey(brief)).font(.system(size: 12.5)).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                } else if let error = smart.briefError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Tokens.error)
                } else {
                    Text("Writing your brief…").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
            }
        }
        .onAppear { smart.loadBrief() }
    }
}
