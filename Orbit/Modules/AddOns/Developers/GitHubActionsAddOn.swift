import SwiftUI

/// The latest GitHub Actions runs for the repos you pick. Alerts when a run on the default branch fails.
@MainActor
@Observable
final class GitHubActionsAddOn: AddOnModule {
    let id = "addon.ghactions"
    let title = "Actions"
    let symbol = "play.circle"
    let addOn = AddOnInfo(category: .developers, tier: .pro,
                          summary: "Watch GitHub Actions runs and hear about failures on your main branch.")

    struct Saved: Codable {
        var repos: [String] = []
        var alerted: [Int] = []
    }

    private let ctx: AddOnContext
    private(set) var repos: [String] = []
    private(set) var runs: [String: [ActionsRun]] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var hasToken = true
    private(set) var loading = false
    private(set) var updated: Date?
    private var defaultBranches: [String: String] = [:]
    private var alerted: [Int] = []
    private var timer: Timer?
    var draft = ""

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        let saved = Storage.load(Saved.self, from: "addon-ghactions") ?? Saved()
        repos = saved.repos
        alerted = saved.alerted
        if ModuleRegistry.isPreview { loadSample() }
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func save() { Storage.save(Saved(repos: repos, alerted: alerted), to: "addon-ghactions") }

    func addRepo() {
        guard let repo = ActionsParsing.normalizeRepo(draft) else { return }
        draft = ""
        guard !repos.contains(where: { $0.lowercased() == repo.lowercased() }) else { return }
        repos.append(repo)
        save()
        refresh()
    }

    func remove(_ repo: String) {
        repos.removeAll { $0 == repo }
        runs[repo] = nil
        errors[repo] = nil
        save()
    }

    func refresh() {
        guard !ModuleRegistry.isPreview, !loading else { return }
        loading = true
        Task {
            defer { loading = false; updated = .now }
            guard let token = await GitHubReviews.token() else { hasToken = false; return }
            hasToken = true
            for repo in repos { await load(repo, token: token) }
        }
    }

    private func request(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    private func load(_ repo: String, token: String) async {
        do {
            if defaultBranches[repo] == nil {
                let (data, _) = try await URLSession.shared.data(for: request(repo, token: token))
                defaultBranches[repo] = ActionsParsing.defaultBranch(data)
            }
            let (data, response) = try await URLSession.shared.data(for: request("\(repo)/actions/runs?per_page=5", token: token))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                errors[repo] = code == 404 ? "Repo not found, or the token can't see it." : "GitHub said \(code)."
                return
            }
            let list = ActionsParsing.runs(data)
            errors[repo] = nil
            runs[repo] = list
            checkFailures(repo, list)
        } catch {
            errors[repo] = "Couldn't reach GitHub."
        }
    }

    private func checkFailures(_ repo: String, _ list: [ActionsRun]) {
        let branch = defaultBranches[repo] ?? "main"
        for run in list where run.state == .failure && run.branch == branch && !alerted.contains(run.id) {
            alerted.append(run.id)
            // Only tell about recent failures, not ones from before Orbit was watching.
            guard Date.now.timeIntervalSince(run.updated) < 6 * 3600 else { continue }
            let url = run.url
            ctx.alerts.post(NotchAlert(
                symbol: "xmark.octagon.fill", tint: Tokens.error,
                title: "\(run.workflow) failed",
                subtitle: "\(repo) · \(run.branch)",
                actions: [.init(title: "Later"), .init(title: "Open", isPrimary: true) { DevActions.open(url) }],
                duration: 8, sound: "Basso"))
        }
        if alerted.count > 300 { alerted.removeFirst(alerted.count - 300) }
        save()
    }

    // MARK: Glances

    private var inProgress: (String, ActionsRun)? {
        for repo in repos { if let r = runs[repo]?.first(where: { $0.state == .running }) { return (repo, r) } }
        return nil
    }

    var runningCount: Int { repos.reduce(0) { $0 + (runs[$1]?.filter { $0.state == .running }.count ?? 0) } }

    var peekChip: PeekChip? {
        guard let (repo, run) = inProgress else { return nil }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return PeekChip(symbol: "arrow.triangle.2.circlepath", text: "\(name) · \(run.workflow)", tint: Tokens.zoom, priority: 2)
    }

    var attention: Attention? {
        guard !ModuleRegistry.isPreview else { return nil }
        for repo in repos {
            let branch = defaultBranches[repo] ?? "main"
            if let latest = runs[repo]?.first(where: { $0.branch == branch }), latest.state == .failure {
                return Attention(id: "ghactions.\(latest.id)", symbol: "xmark.octagon.fill", tint: Tokens.error,
                                 label: "CI failed", priority: 2, headline: "\(latest.workflow) failed on \(repo)")
            }
        }
        return nil
    }

    /// The run to show at a glance: one in progress if there is one, else the most recent.
    var headline: (repo: String, run: ActionsRun)? {
        if let r = inProgress { return (r.0, r.1) }
        return repos.compactMap { repo in runs[repo]?.first.map { (repo: repo, run: $0) } }
            .max { $0.run.updated < $1.run.updated }
    }

    /// Orbit celebrates a pass for a quarter of an hour, then just looks pleased.
    static func isFresh(_ run: ActionsRun, now: Date = .now) -> Bool {
        run.state == .success && now.timeIntervalSince(run.updated) < 15 * 60
    }

    var homeCard: AnyView? { AnyView(ActionsHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(ActionsPanel(module: self)) }

    // MARK: Sample (layout snapshots only)

    private func loadSample() {
        repos = ["acme/app", "acme/website"]
        let now = Date.now
        func r(_ id: Int, _ wf: String, _ title: String, _ br: String, _ st: ActionsRun.State, _ mins: Double) -> ActionsRun {
            ActionsRun(id: id, workflow: wf, title: title, branch: br, state: st, url: "https://github.com",
                       updated: now.addingTimeInterval(-mins * 60))
        }
        runs = [
            "acme/app": [r(1, "CI", "Add developer add-ons", "main", .running, 1),
                                 r(2, "CI", "Tidy up the peek row", "feature/peek", .success, 42),
                                 r(3, "Release", "v1.4.0", "main", .success, 180)],
            "acme/website": [r(4, "Deploy", "Update pricing copy", "main", .failure, 12),
                                   r(5, "Lint", "Fix footer links", "fix/footer", .queued, 2)],
        ]
        updated = now
    }
}

// MARK: - Parsing (pure, tested)

struct ActionsRun: Identifiable, Equatable {
    enum State: Equatable { case queued, running, success, failure, cancelled, other }
    let id: Int
    let workflow: String
    let title: String
    let branch: String
    let state: State
    let url: String
    let updated: Date
}

enum ActionsParsing {
    private struct Response: Decodable { let workflow_runs: [Run] }
    private struct Run: Decodable {
        let id: Int
        let name: String?
        let display_title: String?
        let head_branch: String?
        let status: String?
        let conclusion: String?
        let html_url: String
        let updated_at: String?
        let created_at: String?
    }
    private struct Repo: Decodable { let default_branch: String? }

    static func state(status: String?, conclusion: String?) -> ActionsRun.State {
        switch status {
        case "queued", "waiting", "pending", "requested": return .queued
        case "in_progress": return .running
        case "completed":
            switch conclusion {
            case "success": return .success
            case "failure", "timed_out", "startup_failure": return .failure
            case "cancelled": return .cancelled
            default: return .other
            }
        default: return .other
        }
    }

    static func runs(_ data: Data) -> [ActionsRun] {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return r.workflow_runs.map { run in
            ActionsRun(id: run.id, workflow: run.name ?? "Workflow", title: run.display_title ?? "",
                       branch: run.head_branch ?? "", state: state(status: run.status, conclusion: run.conclusion),
                       url: run.html_url,
                       updated: (run.updated_at ?? run.created_at).flatMap(DevFormat.isoDate) ?? .distantPast)
        }
    }

    static func defaultBranch(_ data: Data) -> String? {
        (try? JSONDecoder().decode(Repo.self, from: data))?.default_branch
    }

    /// "owner/repo", "https://github.com/owner/repo(.git)" or "git@github.com:owner/repo.git" → "owner/repo".
    static func normalizeRepo(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        if t.hasSuffix(".git") { t = String(t.dropLast(4)) }
        let parts = t.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let owner = String(parts[0]), name = String(parts[1])
        guard [owner, name].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return "\(owner)/\(name)"
    }
}

// MARK: - Panel

private struct ActionsPanel: View {
    @Bindable var module: GitHubActionsAddOn

    var subtitle: String {
        guard let updated = module.updated else { return "Latest workflow runs" }
        let age = DevFormat.age(updated)
        return "Latest workflow runs · updated \(age == "now" ? "just now" : "\(age) ago")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: "play.circle.fill", title: "GitHub Actions", subtitle: subtitle, tint: AddOnCategory.developers.tint)
                if let h = module.headline {
                    // Orbit works along with a running build, celebrates a pass and sounds the alarm at a failure.
                    DevActionsOrbit(size: 36, state: h.run.state, fresh: GitHubActionsAddOn.isFresh(h.run))
                        .help("\(h.run.workflow) · \(ActionsWords.state(h.run.state))")
                }
                DevField(placeholder: "owner/repo", text: $module.draft, monospaced: true) { module.addRepo() }
                    .frame(width: 170)
                GlassPillButton(title: "Add", symbol: "plus") { module.addRepo() }
                DevIconButton(symbol: "arrow.clockwise", help: "Refresh") { module.refresh() }
            }
            if !module.hasToken {
                DevEmptyState(symbol: "key.fill", title: "Add a GitHub token",
                              message: "Open Settings → Developer and paste a token with access to Actions, or sign in with the GitHub CLI (gh auth login).",
                              tint: Tokens.attention,
                              art: AnyView(OrbitView(size: 60, mood: .wide, motion: .nudge, tint: Tokens.attention)))
            } else if module.repos.isEmpty {
                DevEmptyState(symbol: "shippingbox", title: "No repos yet",
                              message: "Add a repo like owner/repo and Orbit keeps an eye on its runs.",
                              art: AnyView(OrbitView(size: 60, mood: .happy, motion: .idle)))
            } else {
                NotchScroll {
                    VStack(spacing: 10) {
                        ForEach(module.repos, id: \.self) { repo in repoCard(repo) }
                    }
                }
            }
        }
    }

    func repoCard(_ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                Text(repo).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                Spacer()
                Button { module.remove(repo) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.faint)
                }.buttonStyle(.plain).help("Stop watching \(repo)")
            }
            if let error = module.errors[repo] {
                Text(error).font(.system(size: 12)).foregroundStyle(Tokens.error)
            } else if let list = module.runs[repo] {
                if list.isEmpty { Text("No runs yet.").font(.system(size: 12)).foregroundStyle(Tokens.secondary) }
                ForEach(list) { run in runRow(run) }
            } else {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
            }
        }
        .padding(12)
        .glassCard(18)
    }

    func runRow(_ run: ActionsRun) -> some View {
        Button { DevActions.open(run.url) } label: {
            HStack(spacing: 10) {
                RunIcon(state: run.state)
                Text(run.workflow).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(run.title).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                Spacer(minLength: 6)
                DevTag(text: run.branch)
                Text(DevFormat.age(run.updated)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Tokens.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Open run on GitHub")
    }
}

private struct RunIcon: View {
    let state: ActionsRun.State
    var body: some View {
        let (symbol, tint): (String, Color) = switch state {
        case .queued: ("clock", Tokens.attention)
        case .running: ("arrow.triangle.2.circlepath", Tokens.zoom)
        case .success: ("checkmark.circle.fill", Tokens.live)
        case .failure: ("xmark.circle.fill", Tokens.error)
        case .cancelled: ("slash.circle", Tokens.faint)
        case .other: ("circle.dashed", Tokens.faint)
        }
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
    }
}

enum ActionsWords {
    static func state(_ s: ActionsRun.State) -> String {
        switch s {
        case .queued: "queued"
        case .running: "running"
        case .success: "passed"
        case .failure: "failed"
        case .cancelled: "cancelled"
        case .other: "finished"
        }
    }
}

/// Home: the run in progress, or the latest one, with Orbit acting out how it's going.
private struct ActionsHomeCard: View {
    let module: GitHubActionsAddOn
    let open: () -> Void

    var body: some View {
        if let h = module.headline {
            let name = h.repo.split(separator: "/").last.map(String.init) ?? h.repo
            let age = DevFormat.age(h.run.updated)
            DevSecHomeCard(label: "GitHub Actions",
                           title: "\(h.run.workflow) \(ActionsWords.state(h.run.state))",
                           detail: "\(name) · \(h.run.branch) · \(age == "now" ? "just now" : age + " ago")",
                           titleTint: h.run.state == .failure ? Tokens.error : (h.run.state == .success ? Tokens.live : .white),
                           open: open) {
                DevActionsOrbit(size: 50, state: h.run.state, fresh: GitHubActionsAddOn.isFresh(h.run), calm: true)
            }
        } else {
            DevSecHomeCard(label: "GitHub Actions",
                           title: module.hasToken ? "No runs to show" : "Add a GitHub token",
                           detail: module.repos.isEmpty ? "Add a repo to watch its runs" : "Waiting for GitHub",
                           open: open) {
                OrbitView(size: 44, motion: .idle)
            }
        }
    }
}
