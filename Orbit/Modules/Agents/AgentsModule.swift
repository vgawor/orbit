import AppKit
import SwiftUI
import OrbitKit

/// Coding agents, terminal progress and GitHub reviews in one place.
/// Fed by the local API (the `orbit` CLI and Claude Code hooks) and by GitHub.
@MainActor
@Observable
final class AgentsModule: NotchModule {
    let id = "agents"
    let title = "Agents"
    let symbol = "chevron.left.forwardslash.chevron.right"

    struct Session: Identifiable, Equatable {
        enum State { case working, needsInput, done }
        let id: String
        var agent: String
        var project: String
        var state: State
        var detail: String
        var updated: Date
    }

    struct PendingAsk: Identifiable {
        let id = UUID()
        let request: AskRequest
        let continuation: CheckedContinuation<String?, Never>
    }

    private(set) var items: [APIItem] = []
    private(set) var sessions: [Session] = []
    private(set) var asks: [PendingAsk] = []

    /// Today's Claude Code activity, for the Home feed's Usage view.
    struct Usage {
        var day = Calendar.current.startOfDay(for: .now)
        var sessions: Set<String> = []
        var toolRuns = 0
        var workingSeconds: TimeInterval = 0
        var workingSince: [String: Date] = [:]

        var workingNow: TimeInterval {
            workingSeconds + workingSince.values.reduce(0) { $0 + Date.now.timeIntervalSince($1) }
        }
    }
    private(set) var usage = Usage()

    private func recordUsage(_ id: String, event: String, working: Bool) {
        if !Calendar.current.isDateInToday(usage.day) { usage = Usage() }
        usage.sessions.insert(id)
        if event == "PreToolUse" { usage.toolRuns += 1 }
        if working {
            if usage.workingSince[id] == nil { usage.workingSince[id] = .now }
        } else if let start = usage.workingSince.removeValue(forKey: id) {
            usage.workingSeconds += Date.now.timeIntervalSince(start)
        }
    }
    let github = GitHubReviews()
    /// Claude Code tasks Orbit starts and steers (Agents screen).
    let runner: AgentRunner
    /// Smart Ask, shown as the "Orbit" conversation in the Agents list.
    weak var smart: SmartAssistant?

    /// An approval question from a Claude Code session in your terminal.
    struct TerminalApproval: Identifiable {
        let id = UUID()
        let sessionID: String
        let what: String
        let detail: String?
        let continuation: CheckedContinuation<AgentPermission.Decision, Never>
    }
    private(set) var terminalApprovals: [TerminalApproval] = []
    /// What the Agents screen shows on the right: "overview", "new", a run id or a terminal session id.
    var selection = "overview"
    /// The New agent task form, kept here so it survives the notch closing (e.g. while choosing a folder).
    var draftFolder: String?
    var draftPrompt = ""

    var alertOnFinish: Bool {
        get { UserDefaults.standard.object(forKey: "agents.alertOnFinish") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agents.alertOnFinish") }
    }

    private let alerts: AlertCenter
    private var timer: Timer?

    init(alerts: AlertCenter) {
        self.alerts = alerts
        self.runner = AgentRunner(alerts: alerts)
    }

    func start() {
        github.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    func stop() {
        github.stop()
        timer?.invalidate()
    }

    private func expire() {
        let now = Date.now
        items.removeAll { ($0.expiresAt ?? .distantFuture) < now }
        sessions.removeAll { $0.state == .done && now.timeIntervalSince($0.updated) > 1800 }
    }

    // MARK: API routing

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        switch (req.method, req.path) {
        case ("GET", "/v1/status"):
            return .json(StatusResponse(ok: true, version: version, items: items.count))
        case ("GET", "/v1/items"):
            return .json(items)
        case ("GET", "/v1/sessions"):
            return .json(sessions.map { ["id": $0.id, "agent": $0.agent, "project": $0.project,
                                         "state": "\($0.state)", "detail": $0.detail] })
        case ("POST", "/v1/items"):
            guard var item = try? APIJSON.decoder.decode(APIItem.self, from: req.body) else {
                return .error(400, "Body must be an item: {\"title\": \"…\"}")
            }
            item.updated = .now
            upsert(item)
            return .json(item)
        case ("DELETE", let path) where path.hasPrefix("/v1/items/"):
            let id = String(path.dropFirst("/v1/items/".count)).removingPercentEncoding ?? ""
            let existed = items.contains { $0.id == id }
            items.removeAll { $0.id == id }
            return existed ? .json(["removed": id]) : .error(404, "No item with id \(id)")
        case ("POST", "/v1/ask"):
            guard let ask = try? APIJSON.decoder.decode(AskRequest.self, from: req.body), !ask.actions.isEmpty else {
                return .error(400, "Body must be {\"title\": \"…\", \"actions\": [\"Yes\", \"No\"]}")
            }
            let choice = await self.ask(ask)
            return .json(AskResponse(choice: choice), status: choice == nil ? 408 : 200)
        case ("POST", "/v1/agents/permission"):
            let json = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
            if json["terminal"] as? Bool == true {
                return .json(await requestTerminalPermission(json))
            }
            return .json(await runner.requestPermission(req.body))
        case ("POST", "/v1/hooks/claude"):
            handleClaudeHook(req.body)
            return .json(["ok": true])
        default:
            return .error(404, "Unknown endpoint \(req.method) \(req.path)")
        }
    }

    private func upsert(_ item: APIItem) {
        let previous = items.first { $0.id == item.id }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.insert(item, at: 0) }
        // Tell you when something you were waiting on finishes.
        let finished = item.status == .success || item.status == .error
        if finished, previous?.status != item.status {
            alerts.post(NotchAlert(
                symbol: item.status == .success ? "checkmark" : "xmark",
                tint: item.status == .success ? Tokens.live : Tokens.error,
                title: item.title + (item.status == .success ? " finished" : " failed"),
                subtitle: item.subtitle ?? item.source ?? "From your terminal",
                actions: [.init(title: "OK", isPrimary: true)], duration: 6,
                sound: item.status == .success ? "Glass" : "Basso"))
        }
    }

    /// Shows the question in the notch and waits for a click (or the timeout).
    func ask(_ request: AskRequest) async -> String? {
        let timeout = min(max(request.timeout ?? 60, 5), 3600)
        return await withCheckedContinuation { cont in
            let pending = PendingAsk(request: request, continuation: cont)
            asks.append(pending)
            let actions = request.actions.enumerated().map { i, title in
                NotchAlert.Action(title: title, isPrimary: i == request.actions.count - 1) { [weak self] in
                    self?.answer(pending.id, with: title)
                }
            }
            alerts.post(NotchAlert(symbol: "questionmark", tint: Tokens.attention, title: request.title,
                                   subtitle: request.subtitle ?? "From your terminal", actions: actions,
                                   duration: timeout, sound: "Tink"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.answer(pending.id, with: nil)
            }
        }
    }

    func answer(_ id: UUID, with choice: String?) {
        guard let i = asks.firstIndex(where: { $0.id == id }) else { return }
        let pending = asks.remove(at: i)
        pending.continuation.resume(returning: choice)
    }

    // MARK: Approvals for terminal sessions

    /// A Claude Code session in your terminal wants your OK. Asks in the notch; if you don't answer
    /// (or pick "In terminal"), Claude asks in the terminal as usual. Never approves on its own.
    func requestTerminalPermission(_ json: [String: Any]) async -> AgentPermission.Decision {
        let sessionID = json["session_id"] as? String ?? UUID().uuidString
        let input = json["tool_input"] as? [String: Any]
        let what = AgentRun.describeTool(json["tool_name"] as? String, input)
        let detail = (input?["command"] as? String) ?? (input?["file_path"] as? String) ?? (input?["url"] as? String)
        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent

        var session = sessions.first { $0.id == sessionID }
            ?? Session(id: sessionID, agent: "Claude Code", project: project, state: .needsInput, detail: what, updated: .now)
        session.state = .needsInput
        session.detail = "Allow? \(what)"
        session.updated = .now
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i] = session } else { sessions.insert(session, at: 0) }

        return await withCheckedContinuation { cont in
            let approval = TerminalApproval(sessionID: sessionID, what: what, detail: detail, continuation: cont)
            terminalApprovals.append(approval)
            let id = approval.id
            alerts.post(NotchAlert(symbol: "hand.raised.fill", tint: Tokens.attention,
                                   title: "Allow? \(what)", subtitle: "Claude Code · \(project)",
                                   actions: [
                                       .init(title: "In terminal") { [weak self] in self?.decideTerminal(id, .askInTerminal) },
                                       .init(title: "Deny") { [weak self] in self?.decideTerminal(id, .deny("Denied in Orbit")) },
                                       .init(title: "Allow", isPrimary: true) { [weak self] in self?.decideTerminal(id, .allow) },
                                   ],
                                   duration: AgentPermission.terminalAnswerTimeout, sound: "Tink"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(AgentPermission.terminalAnswerTimeout))
                self?.decideTerminal(id, .askInTerminal)
            }
        }
    }

    /// Answers a terminal approval. Only the first answer counts.
    func decideTerminal(_ id: UUID, _ decision: AgentPermission.Decision) {
        guard let i = terminalApprovals.firstIndex(where: { $0.id == id }) else { return }
        let approval = terminalApprovals.remove(at: i)
        if let s = sessions.firstIndex(where: { $0.id == approval.sessionID }) {
            switch decision.behavior {
            case "allow": sessions[s].state = .working; sessions[s].detail = "Allowed: \(approval.what)"
            case "deny": sessions[s].state = .working; sessions[s].detail = "Denied: \(approval.what)"
            default: sessions[s].detail = "Asking in the terminal"
            }
        }
        approval.continuation.resume(returning: decision)
    }

    // MARK: Claude Code hooks

    private func handleClaudeHook(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessionID = json["session_id"] as? String,
              let event = json["hook_event_name"] as? String else { return }
        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent
        var session = sessions.first { $0.id == sessionID }
            ?? Session(id: sessionID, agent: "Claude Code", project: project, state: .working, detail: "Started", updated: .now)
        session.updated = .now

        switch event {
        case "SessionStart":
            session.state = .working; session.detail = "Session started"
        case "UserPromptSubmit":
            session.state = .working; session.detail = "Thinking…"
        case "PreToolUse":
            session.state = .working
            session.detail = Self.describeTool(json["tool_name"] as? String, json["tool_input"] as? [String: Any])
        case "Notification" where runner.ownSessionIDs.contains(sessionID):
            return
        case "Notification":
            let message = json["message"] as? String ?? "Claude needs your input"
            session.state = .needsInput
            session.detail = message
            alerts.post(NotchAlert(symbol: "hand.raised.fill", tint: Tokens.attention,
                                   title: "Claude Code needs you · \(project)", subtitle: message,
                                   actions: [.init(title: "OK", isPrimary: true)], duration: 15, sound: "Tink"))
        case "Stop":
            session.state = .done; session.detail = "Finished"
            if alertOnFinish && !runner.ownSessionIDs.contains(sessionID) {
                alerts.post(NotchAlert(symbol: "checkmark", tint: Tokens.live, title: "Claude finished · \(project)",
                                       subtitle: "Your turn", actions: [.init(title: "OK", isPrimary: true)], duration: 5))
            }
        case "SessionEnd":
            recordUsage(sessionID, event: event, working: false)
            sessions.removeAll { $0.id == sessionID }
            return
        default:
            return
        }
        recordUsage(sessionID, event: event, working: session.state == .working)
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i] = session } else { sessions.insert(session, at: 0) }
    }

    private static func describeTool(_ name: String?, _ input: [String: Any]?) -> String {
        let file = (input?["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing \(file ?? "a file")"
        case "Read": return "Reading \(file ?? "a file")"
        case "Bash":
            let cmd = (input?["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running \(cmd.prefix(60))"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch": return "Looking things up"
        case "Task", "Agent": return "Working with a helper agent"
        case let other?: return "Using \(other)"
        case nil: return "Working"
        }
    }

    // MARK: Views

    /// Claude Code sessions started in a terminal (Orbit's own runs are shown separately).
    var terminalSessions: [Session] { sessions.filter { !runner.ownSessionIDs.contains($0.id) } }

    var peekView: AnyView? {
        if !asks.isEmpty || runner.waitingCount > 0 || terminalSessions.contains(where: { $0.state == .needsInput }) {
            return AnyView(HStack(spacing: 6) {
                Circle().fill(Tokens.attention).frame(width: 8, height: 8)
                Text("Needs you")
            })
        }
        if let item = items.first(where: { $0.status == .active }) {
            return AnyView(HStack(spacing: 6) {
                Circle().fill(Tokens.live).frame(width: 8, height: 8)
                Text(item.progress.map { "\(Int($0 * 100))%" } ?? item.title)
            })
        }
        if runner.workingCount > 0 || terminalSessions.contains(where: { $0.state == .working }) {
            return AnyView(HStack(spacing: 6) {
                PulsingDot(color: Tokens.live, size: 8)
                Text("Working")
            })
        }
        return nil
    }

    var peekChip: PeekChip? {
        if !asks.isEmpty {
            return PeekChip(symbol: "questionmark.circle.fill", text: "Question waiting", tint: Tokens.attention, priority: 6)
        }
        if let r = runner.runs.first(where: { $0.state == .waiting }) {
            return PeekChip(symbol: "hand.raised.fill", text: "Agent needs your OK · \(r.name)", tint: Tokens.attention, priority: 6, target: "agents")
        }
        if let s = terminalSessions.first(where: { $0.state == .needsInput }) {
            return PeekChip(symbol: "hand.raised.fill", text: "Claude needs you · \(s.project)", tint: Tokens.attention, priority: 6)
        }
        if let r = runner.runs.first(where: { $0.state == .working }) {
            return PeekChip(symbol: "sparkle", text: "Agent · \(r.lastLine)", tint: Tokens.live, priority: 1, target: "agents")
        }
        if let s = terminalSessions.first(where: { $0.state == .working }) {
            return PeekChip(symbol: "sparkle", text: "Claude · \(s.detail)", tint: Tokens.live, priority: 1)
        }
        return nil
    }

    var attention: Attention? {
        if let ask = asks.first {
            return Attention(id: "ask-\(ask.id)", symbol: "questionmark", tint: Tokens.attention, label: "Question", priority: 4, headline: "Question waiting")
        }
        if let t = terminalApprovals.first {
            return Attention(id: "approval-\(t.id)", symbol: "hand.raised.fill", tint: Tokens.attention,
                             label: "Claude", priority: 4, headline: "Claude needs your OK")
        }
        if let r = runner.runs.first(where: { $0.state == .waiting }) {
            return Attention(id: "run-\(r.id)-\(r.messages.count)", symbol: "hand.raised.fill", tint: Tokens.attention,
                             label: "Agent", priority: 4, headline: "Agent needs your OK")
        }
        if let s = terminalSessions.first(where: { $0.state == .needsInput }) {
            return Attention(id: "claude-\(s.id)-\(s.updated.timeIntervalSince1970)", symbol: "hand.raised.fill",
                             tint: Tokens.attention, label: "Claude", priority: 4, headline: "Claude needs you")
        }
        return nil
    }

    var runningCount: Int {
        terminalSessions.filter { $0.state == .working }.count + items.filter { $0.status == .active }.count + runner.workingCount
    }

    var peekPriority: Int {
        if !asks.isEmpty || runner.waitingCount > 0 || terminalSessions.contains(where: { $0.state == .needsInput }) { return 3 }
        if items.contains(where: { $0.status == .active }) { return 2 }
        return 0
    }

    var panel: AnyView { AnyView(AgentsPanel(module: self)) }
}

// MARK: - GitHub

/// Pull requests waiting for your review. Uses a token saved in Settings,
/// or borrows the GitHub CLI's login (`gh auth token`) if you have it.
@MainActor
@Observable
final class GitHubReviews {
    struct PR: Identifiable, Equatable {
        let id: Int
        let title: String
        let repo: String
        let number: Int
        let author: String
        let url: URL
    }

    enum Status: Equatable { case notConnected, loading, ok, failed(String) }

    private(set) var reviews: [PR] = []
    private(set) var status: Status = .notConnected
    private(set) var lastChecked: Date?
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() { timer?.invalidate() }

    func refresh() async {
        guard let token = await Self.token() else { status = .notConnected; reviews = []; return }
        if reviews.isEmpty { status = .loading }
        var req = URLRequest(url: URL(string: "https://api.github.com/search/issues?q=is:open+is:pr+review-requested:@me+archived:false&sort=updated&per_page=20")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Orbit-notch-app", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = .failed(code == 401 ? "GitHub token was rejected" : "GitHub answered \(code)")
                return
            }
            let result = try JSONDecoder().decode(SearchResult.self, from: data)
            reviews = result.items.map {
                PR(id: $0.id, title: $0.title, repo: $0.repository_url.split(separator: "/").suffix(2).joined(separator: "/"),
                   number: $0.number, author: $0.user.login, url: $0.html_url)
            }
            status = .ok
            lastChecked = .now
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private struct SearchResult: Decodable {
        struct Item: Decodable {
            struct User: Decodable { let login: String }
            let id: Int, number: Int, title: String, html_url: URL, repository_url: String, user: User
        }
        let items: [Item]
    }

    /// Settings token first, then the GitHub CLI's.
    static func token() async -> String? {
        if let saved = Secrets.get("github"), !saved.isEmpty { return saved }
        return await Task.detached { ghCLIToken() }.value
    }

    nonisolated static func ghCLIToken() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let token = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil
        }
        return nil
    }
}

// MARK: - Views

struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
    }
}

struct AgentsPanel: View {
    let module: AgentsModule

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sidebar.frame(width: 214)
            Group {
                if module.selection == "new" {
                    NewAgentTaskView(module: module)
                } else if module.selection == "orbit", let smart = module.smart {
                    OrbitChatPane(smart: smart)
                } else if let run = module.runner.run(module.selection) {
                    AgentChatView(run: run, module: module)
                } else if let s = module.terminalSessions.first(where: { $0.id == module.selection }) {
                    terminalSession(s)
                } else {
                    overview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Left: conversations

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { module.selection = "new" } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New agent task").font(.system(size: 12.5, weight: .semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Capsule().fill(.white)).foregroundStyle(.black)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            NotchScroll {
                VStack(alignment: .leading, spacing: 2) {
                    if let smart = module.smart {
                        conversation(id: "orbit", title: "Orbit", subtitle: orbitSubtitle(smart),
                                     hot: smart.pending != nil) {
                            OrbitView(size: 30, mood: smart.pending != nil ? .wide : .normal,
                                      motion: smart.busy ? .thinking : smart.pending != nil ? .glow : .idle)
                        }
                    }
                    conversation(id: "overview", title: "Overview",
                                 subtitle: overviewSubtitle) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 14))
                            .foregroundStyle(module.asks.isEmpty ? Tokens.secondary : Tokens.attention)
                            .frame(width: 30, height: 30).glassSurface(Circle())
                    }
                    if !module.runner.runs.isEmpty {
                        heading("Started in Orbit")
                        ForEach(module.runner.runs) { run in
                            conversation(id: run.id, title: run.name, subtitle: run.lastLine,
                                         hot: run.state == .waiting) { AgentOrbit(run: run, size: 30) }
                        }
                    }
                    if !module.terminalSessions.isEmpty {
                        heading("From your terminal")
                        ForEach(module.terminalSessions) { s in
                            conversation(id: s.id, title: s.project, subtitle: s.detail, hot: s.state == .needsInput) {
                                OrbitView.agent(project: s.project, state: s.state, size: 30)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(24)
    }

    private func orbitSubtitle(_ smart: SmartAssistant) -> String {
        if smart.busy { return "Thinking…" }
        if smart.pending != nil { return "Waiting for your OK" }
        if !smart.isConfigured { return "Add a Claude key to chat" }
        return smart.turns.isEmpty ? "Ask anything" : "Your conversation"
    }

    private var overviewSubtitle: String {
        if !module.asks.isEmpty { return "\(module.asks.count) question\(module.asks.count == 1 ? "" : "s") waiting" }
        let reviews = module.github.reviews.count
        return reviews > 0 ? "\(reviews) review\(reviews == 1 ? "" : "s") on GitHub" : "Terminal jobs and GitHub"
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.secondary)
            .padding(.top, 10).padding(.bottom, 2).padding(.leading, 6)
    }

    private func conversation<Icon: View>(id: String, title: String, subtitle: String, hot: Bool = false,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        let selected = module.selection == id
        return Button { module.selection = id } label: {
            HStack(spacing: 9) {
                icon().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if hot { Circle().fill(Tokens.attention).frame(width: 6, height: 6) }
                    }
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(hot ? Tokens.attention : Tokens.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.white.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Right: overview (questions, terminal jobs, GitHub)

    private var overview: some View {
        NotchScroll {
            VStack(alignment: .leading, spacing: 8) {
                if !module.asks.isEmpty {
                    CardLabel("Questions")
                    ForEach(module.asks) { ask in askRow(ask) }
                }
                CardLabel("From your terminal")
                if module.items.isEmpty {
                    Text("Try: orbit run -- npm test").font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.faint)
                }
                ForEach(module.items.prefix(4)) { itemRow($0) }
                CardLabel("GitHub reviews").padding(.top, 6)
                githubSection
                if module.runner.runs.isEmpty && module.terminalSessions.isEmpty {
                    HStack(spacing: 12) {
                        OrbitView(size: 46, mood: .normal, motion: .idle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Give Claude Code a task").font(.system(size: 13, weight: .semibold))
                            Text("Pick a project folder and say what to do. Orbit asks you before anything changes.")
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .glassCard(24)
    }

    private func terminalSession(_ s: AgentsModule.Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                OrbitView.agent(project: s.project, state: s.state, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.project).font(.system(size: 15, weight: .semibold))
                    Text("\(s.agent) · started in your terminal").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                }
            }
            Text(s.detail).font(.system(size: 13))
            ForEach(module.terminalApprovals.filter { $0.sessionID == s.id }) { a in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                        Text("Allow? \(a.what)").font(.system(size: 13, weight: .semibold))
                    }
                    if let d = a.detail {
                        Text(d).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.secondary).lineLimit(4)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                    }
                    HStack(spacing: 8) {
                        GlassPillButton(title: "In terminal") { module.decideTerminal(a.id, .askInTerminal) }
                        Spacer()
                        GlassPillButton(title: "Deny") { module.decideTerminal(a.id, .deny("Denied in Orbit")) }
                        PillButton(title: "Allow") { module.decideTerminal(a.id, .allow) }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tokens.attention.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.attention.opacity(0.5)))
            }
            Text("This session runs in your terminal. When it needs your OK, you can answer here or in the terminal. To chat with it, use the terminal.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sessionRow(_ s: AgentsModule.Session) -> some View {
        row {
            HStack(alignment: .top, spacing: 10) {
                OrbitView.agent(project: s.project, state: s.state, size: 30)
                    .padding(.top, -4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(s.agent) · \(s.project)").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(s.detail).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(2)
                }
                Spacer()
                Text(s.updated, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
            }
        }
    }

    private func askRow(_ ask: AgentsModule.PendingAsk) -> some View {
        row {
            VStack(alignment: .leading, spacing: 6) {
                Text(ask.request.title).font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(ask.request.actions, id: \.self) { action in
                        PillButton(title: action, fill: action == ask.request.actions.last ? .white : Tokens.surface) {
                            module.answer(ask.id, with: action)
                        }
                    }
                }
            }
        }
    }

    private func itemRow(_ item: APIItem) -> some View {
        row {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle().fill(color(item.status)).frame(width: 6, height: 6)
                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button { module.handleRemove(item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.faint)
                    }.buttonStyle(.plain)
                }
                if let sub = item.subtitle {
                    Text(sub).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
                if let p = item.progress { ProgressBar(value: p, tint: color(item.status)) }
            }
        }
    }

    @ViewBuilder private var githubSection: some View {
        let gh = module.github
        switch gh.status {
        case .notConnected:
            Text("Add a GitHub token in Settings → Developer, or sign in with the gh tool.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let why):
            Text(why).font(.system(size: 11.5)).foregroundStyle(Tokens.error)
        case .ok:
            if gh.reviews.isEmpty {
                Text("Nothing waiting for your review.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }
            ForEach(gh.reviews.prefix(3)) { pr in
                Button { NSWorkspace.shared.open(pr.url) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Tokens.zoom).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pr.title).font(.system(size: 12)).lineLimit(1)
                            Text("\(pr.repo) #\(pr.number) · \(pr.author)").font(.system(size: 10.5)).foregroundStyle(Tokens.faint).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if gh.reviews.count > 3 {
                Text("+\(gh.reviews.count - 3) more").font(.system(size: 11)).foregroundStyle(Tokens.faint)
            }
        }
    }

    private func color(_ s: APIItem.Status) -> Color {
        switch s {
        case .active: Tokens.live
        case .waiting: Tokens.attention
        case .success: Tokens.live
        case .error: Tokens.error
        }
    }
}

extension AgentsModule {
    func handleRemove(_ id: String) { items.removeAll { $0.id == id } }
}
