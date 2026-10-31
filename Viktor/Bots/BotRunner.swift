import AppKit
import Foundation

/// One run of a bot: a scheduled job, a meeting prep or a "Run now".
struct BotRun: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case scheduled, manual, prep, handoff }
    /// `waiting`: paused until the user answers an approval in the notch.
    enum State: String, Codable { case working, waiting, done, failed, budget }

    /// The cloud session id, "local-…" for ChatGPT runs, or a deployment run id for a run that never started.
    let id: String
    let botID: String
    let kind: Kind
    var title: String
    let started: Date
    var state: State = .working
    var report: String?
    var error: String?
    var costCents: Int?
    var finished: Date?
    var read = false
    /// Tool calls Orbit already answered, so none is answered twice.
    var answered: [String] = []
    /// What happened, in plain words ("Looked at your day", "You approved: Log a note on deal 12").
    var steps: [String] = []

    // ChatGPT runs (on this Mac)
    var provider: BotProvider?
    /// The latest OpenAI response this run continues from.
    var responseID: String?
    /// Tool calls in that response, and the answers collected so far (call id → text).
    var calls: [OpenAIAPI.Turn.Call]?
    var outputs: [String: String]?
    var messages: [String]?
    var tokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var webSearches: Int?
    /// Cloud runs: whose keys started it ("own" or "pro"). nil = own.
    var cloudMode: String?

    // Hand-offs: which run handed this one its task, and how far down the chain it is.
    var parentRunID: String?
    var fromBotID: String?
    var depth: Int?
    var handoffTask: String?

    var engine: BotProvider { provider ?? .claude }
    var isOpen: Bool { state == .working || state == .waiting }
}

/// A change a bot wants to make, waiting for the user: Send, Edit or Skip.
struct BotApproval: Codable, Identifiable, Equatable {
    /// The tool call id (cloud event id or OpenAI call id).
    let id: String
    let runID: String
    let botID: String
    let tool: String
    let inputJSON: String
    /// What the bot wrote just before asking (its reason).
    var reason: String?
    let created: Date

    var input: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any]) ?? [:]
    }
}

/// Something a bot did on its own (a change the user trusts it with). Undo works for 10 minutes.
struct BotAction: Codable, Identifiable, Equatable {
    let id: String
    let botID: String
    let runID: String
    let title: String
    let undo: BotUndo?
    let at: Date
    var undone = false

    static let undoWindow: TimeInterval = 10 * 60
    func canUndo(now: Date = .now) -> Bool { !undone && undo != nil && now.timeIntervalSince(at) < Self.undoWindow }
}

/// "Let Account Manager create tasks on its own?", offered after enough plain approvals.
struct TrustOffer: Codable, Identifiable, Equatable {
    let botID: String
    let tool: String
    var id: String { botID + "/" + tool }
}

/// Watches bot runs, answers the tools they call (through the safety gate), queues changes for
/// the user's approval and collects reports. Claude bots run in the cloud (polled every minute, on
/// wake and when asked); ChatGPT bots run right here while the Mac is awake.
@MainActor
@Observable
final class BotRunner {
    private(set) var runs: [BotRun]
    private(set) var approvals: [BotApproval]
    /// Changes bots made on their own, newest last.
    private(set) var actions: [BotAction]
    private(set) var trustOffers: [TrustOffer]
    private(set) var lastError: String?
    private(set) var lastCheck: Date?
    private(set) var checking = false
    /// Approvals being carried out right now (button spinners).
    private(set) var deciding: Set<String> = []

    let store: BotStore
    private let tools: OrbitTools
    /// Called when a run finishes with a report, so the notch can show it.
    var onReport: (@MainActor (BotRun) -> Void)?
    /// Called when a bot asks for approval.
    var onApproval: (@MainActor (BotApproval) -> Void)?
    /// Called when a bot made a change on its own (shown with Undo).
    var onAction: (@MainActor (BotAction) -> Void)?
    /// Called when Orbit offers to trust a bot with something.
    var onTrustOffer: (@MainActor (TrustOffer) -> Void)?

    let memory: BotMemory
    /// Plain approvals in a row (no edits) before Orbit offers to let the bot do it on its own.
    nonisolated static let trustAfter = 10

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static let file = "bot-runs"
    private static let approvalsFile = "bot-approvals"
    private static let actionsFile = "bot-actions"
    private static let streakKey = "bots.approvalStreaks"
    private static let offersKey = "bots.trustOffers"
    private static let declinedKey = "bots.trustDeclined"
    private static let lastLocalKey = "bots.lastLocalRun"
    private static let keep = 60
    private let save: Bool
    /// ChatGPT runs being moved along right now, so two ticks don't double up.
    private var localBusy: Set<String> = []

    init(store: BotStore, tools: OrbitTools, memory: BotMemory? = nil, runs: [BotRun]? = nil, save: Bool = true) {
        self.store = store
        self.tools = tools
        self.save = save
        self.memory = memory ?? BotMemory(save: save)
        self.runs = runs ?? Storage.load([BotRun].self, from: Self.file) ?? []
        self.approvals = save ? Storage.load([BotApproval].self, from: Self.approvalsFile) ?? [] : []
        self.actions = save ? Storage.load([BotAction].self, from: Self.actionsFile) ?? [] : []
        let offers = save ? UserDefaults.standard.data(forKey: Self.offersKey).flatMap { try? JSONDecoder().decode([TrustOffer].self, from: $0) } : nil
        self.trustOffers = offers ?? []
        store.isOverCap = { [weak self] bot in self?.isOverCap(bot) ?? false }
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the network a moment to come back.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                await self?.tick()
            }
        }
        Task {
            await store.syncAll()
            await tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Check again in a few seconds (after Run now, an approval, or when the notch opens).
    func checkSoon(after seconds: Double = 0) {
        Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            await tick()
        }
    }

    // MARK: Reading

    func runs(for botID: String) -> [BotRun] { runs.filter { $0.botID == botID }.sorted { $0.started > $1.started } }
    var unread: [BotRun] { runs.filter { !$0.isOpen && !$0.read }.sorted { $0.started > $1.started } }
    var working: [BotRun] { runs.filter { $0.state == .working } }
    /// Runs another bot handed over, newest first.
    var handoffs: [BotRun] { runs.filter { $0.parentRunID != nil }.sorted { $0.started > $1.started } }
    func approvals(for botID: String) -> [BotApproval] { approvals.filter { $0.botID == botID }.sorted { $0.created < $1.created } }
    func isBusy(_ botID: String) -> Bool { runs.contains { $0.botID == botID && $0.isOpen } }

    /// Layout snapshots only: shows these runs and approvals without saving.
    func previewSet(_ runs: [BotRun], approvals: [BotApproval] = [], actions: [BotAction] = [], offers: [TrustOffer] = []) {
        self.runs = runs
        self.approvals = approvals
        self.actions = actions
        self.trustOffers = offers
    }

    func markRead(_ id: String) { change(id) { $0.read = true } }

    // MARK: Starting runs

    /// Runs the bot's scheduled job now.
    func runNow(_ botID: String) async {
        guard let bot = store.bot(botID) else { return }
        if isOverCap(bot) {
            lastError = "\(bot.name) reached its monthly cap of \(Self.dollars(bot.monthlyCap)). Raise it in Settings → Bots, or it resumes next month."
            return
        }
        // A fresh run replaces one still waiting, so it works from today's data and rules.
        await closeOpenRuns(of: botID)
        if bot.engine == .chatgpt {
            await start(botID, kind: .manual, title: Self.title(for: bot, at: .now), message: bot.kickoff)
            return
        }
        if bot.deploymentID == nil { await store.sync(botID) }
        guard let depl = store.bot(botID)?.deploymentID else {
            lastError = store.syncErrors[botID] ?? "Turn the bot on first."
            return
        }
        do {
            try await ManagedAgentsAPI.runDeployment(depl)
            lastError = nil
            checkSoon(after: 4)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Starts a run with its own first message, e.g. "Prepare me for …".
    @discardableResult
    func start(_ botID: String, kind: BotRun.Kind, title: String, message: String) async -> Bool {
        await startRun(botID, kind: kind, title: title, message: message) != nil
    }

    /// Starts a run and returns its id. `parent` links a hand-off to the run that made it.
    private func startRun(_ botID: String, kind: BotRun.Kind, title: String, message: String,
                          parent: (run: BotRun, task: String)? = nil) async -> String? {
        guard let bot = store.bot(botID) else { return nil }
        if isOverCap(bot) {
            lastError = "\(bot.name) reached its monthly cap of \(Self.dollars(bot.monthlyCap)). Raise it in Settings → Bots, or it resumes next month."
            return nil
        }
        func link(_ run: inout BotRun) {
            guard let parent else { return }
            run.parentRunID = parent.run.id
            run.fromBotID = parent.run.botID
            run.depth = (parent.run.depth ?? 0) + 1
            run.handoffTask = parent.task
        }
        switch bot.engine {
        case .chatgpt:
            return startLocal(bot, kind: kind, title: title, message: message, link: link)
        case .claude:
            if bot.agentID == nil { await store.sync(botID) }
            guard let bot = store.bot(botID), let agent = bot.agentID else {
                lastError = store.syncErrors[botID] ?? "This bot isn't set up in the cloud yet."
                return nil
            }
            do {
                let env = try await BotStore.environment(for: bot)
                let id = try await ManagedAgentsAPI.startSession(agentID: agent, environmentID: env, title: "Orbit · \(title)",
                                                                 message: message, budgetCents: bot.budgetCents, botID: bot.id)
                var run = BotRun(id: id, botID: botID, kind: kind, title: title, started: .now)
                run.cloudMode = CloudMode.current.rawValue
                link(&run)
                runs.append(run)
                persist()
                lastError = nil
                checkSoon(after: 3)
                return id
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    // MARK: Approvals

    /// the user's answer to an approval. `edited` replaces fields of the bot's request.
    func decide(_ approvalID: String, approve: Bool, edited: [String: Any]? = nil) async {
        guard let approval = approvals.first(where: { $0.id == approvalID }), !deciding.contains(approvalID),
              let run = runs.first(where: { $0.id == approval.runID }) else { return }
        deciding.insert(approvalID)
        defer { deciding.remove(approvalID) }
        let shown = ApprovalPresentation(tool: approval.tool, input: approval.input)

        let text: String, isError: Bool, step: String
        if approve {
            var input = approval.input
            var edits: [String] = []
            for (key, value) in edited ?? [:] {
                let old = ApprovalPresentation.text(input[key])
                let new = ApprovalPresentation.text(value)
                if old != new { input[key] = value; edits.append("\(key): “\(old)” → “\(new)”") }
            }
            // The gate said "ask"; running it now is the user's own decision.
            let outcome = await performTool(approval.tool, input, botID: approval.botID, runID: run.id)
            let (out, failed) = (outcome.text, outcome.isError)
            text = edits.isEmpty ? out : out + "\n\(UserProfile.firstName) edited it before approving: " + edits.joined(separator: "; ")
                + ". Note how he changed it for next time."
            isError = failed
            step = failed ? "Failed: \(shown.title) (\(out))" : "You approved\(edits.isEmpty ? "" : " with edits"): \(shown.title)"
            countApproval(botID: approval.botID, tool: approval.tool, plain: edits.isEmpty && !failed)
        } else {
            text = "\(UserProfile.firstName) skipped this, so nothing was changed. Don't ask for it again in this run."
            isError = true
            step = "You skipped: \(shown.title)"
            countApproval(botID: approval.botID, tool: approval.tool, plain: false)
        }

        do {
            try await deliver(text, isError: isError, to: approval.id, in: run)
        } catch let e as ManagedAgentsAPI.APIError where e.status == 400 || e.status == 409 {
            // The run stopped waiting (it ended or was answered); nothing more to send.
        } catch {
            lastError = error.localizedDescription
            return
        }
        approvals.removeAll { $0.id == approvalID }
        persistApprovals()
        let othersWaiting = approvals.contains { $0.runID == run.id }
        change(run.id) { $0.steps.append(step); if $0.state == .waiting && !othersWaiting { $0.state = .working } }
        if run.engine == .chatgpt {
            await continueLocal(run.id)
        } else {
            checkSoon(after: 3)
        }
    }

    private func deliver(_ text: String, isError: Bool, to callID: String, in run: BotRun) async throws {
        switch run.engine {
        case .claude:
            let mode = CloudMode(rawValue: run.cloudMode ?? "own") ?? .own
            try await CloudMode.$override.withValue(mode) {
                try await ManagedAgentsAPI.answer(run.id, toolUseID: callID, text: text, isError: isError)
            }
            change(run.id) { $0.answered.append(callID) }
        case .chatgpt:
            change(run.id) { $0.outputs = ($0.outputs ?? [:]).merging([callID: isError ? "Error: " + text : text]) { $1 } }
        }
    }

    private func queue(_ use: SessionDigest.ToolUse, run: BotRun, reason: String?) {
        guard !approvals.contains(where: { $0.id == use.id }) else { return }
        let approval = BotApproval(id: use.id, runID: run.id, botID: run.botID, tool: use.name,
                                   inputJSON: use.inputJSON, reason: reason, created: .now)
        approvals.append(approval)
        persistApprovals()
        onApproval?(approval)
    }

    // MARK: The loop

    func tick() async {
        guard !checking else { return }
        checking = true
        defer { checking = false; lastCheck = .now }
        await startDueLocalRuns()
        for bot in store.bots where bot.enabled && bot.engine == .claude && (bot.pausedForCap ?? false) != isOverCap(bot) {
            await store.sync(bot.id)
        }
        if ManagedAgentsAPI.isConfigured {
            let active = store.bots.filter { $0.deploymentID != nil && $0.engine == .claude }
            do {
                for bot in active {
                    let mode = CloudMode(rawValue: bot.cloudMode ?? "own") ?? .own
                    try await CloudMode.$override.withValue(mode) { try await discover(bot) }
                }
                for run in runs where run.isOpen && run.engine == .claude {
                    if run.started < .now.addingTimeInterval(-3 * 86400) {
                        finish(run.id, state: .failed, report: nil, error: "No answer from the cloud for 3 days.")
                        continue
                    }
                    let mode = CloudMode(rawValue: run.cloudMode ?? "own") ?? .own
                    try await CloudMode.$override.withValue(mode) { try await advance(run.id) }
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        // ChatGPT runs that have everything they need but didn't continue (e.g. Orbit quit).
        for run in runs where run.engine == .chatgpt && run.state == .working { await continueLocal(run.id) }
        prune()
    }

    /// Picks up runs the schedule started in the cloud.
    private func discover(_ bot: Bot) async throws {
        guard let depl = bot.deploymentID else { return }
        let recent = try await ManagedAgentsAPI.recentRuns(deploymentID: depl)
        let cutoff = Date.now.addingTimeInterval(-36 * 3600)
        for r in recent {
            let created = r.createdAt ?? .now
            guard created > cutoff else { continue }
            let id = r.sessionID ?? r.id
            guard !runs.contains(where: { $0.id == id }) else { continue }
            var run = BotRun(id: id, botID: bot.id, kind: .scheduled, title: Self.title(for: bot, at: created), started: created)
            run.cloudMode = bot.cloudMode
            if r.sessionID == nil {
                run.state = .failed
                run.error = r.error ?? "The schedule couldn't start this run."
                run.finished = created
            }
            await closeOpenRuns(of: bot.id, before: created)
            runs.append(run)
        }
        persist()
    }

    /// Closes a bot's open runs (older than `before`, if given) and drops their waiting approvals.
    /// Without this, a run left waiting keeps coming back with what it read days ago.
    func closeOpenRuns(of botID: String, before: Date? = nil) async {
        let old = runs.filter { run in run.botID == botID && run.isOpen && run.parentRunID == nil && (before.map { run.started < $0 } ?? true) }
        for run in old {
            if run.engine == .claude {
                let mode = CloudMode(rawValue: run.cloudMode ?? "own") ?? .own
                _ = try? await CloudMode.$override.withValue(mode) {
                    try await ManagedAgentsAPI.call("POST", "sessions/\(run.id)/events", body: ["events": [["type": "user.interrupt"]]])
                }
            }
            change(run.id) { $0.state = .done; $0.read = true; $0.finished = .now; $0.steps.append("Closed: a newer run took over") }
            dropApprovals(for: run.id)
        }
    }

    /// Moves one cloud run along: answers what it waits for, queues approvals, or collects its report.
    private func advance(_ id: String) async throws {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        let status = try await ManagedAgentsAPI.sessionStatus(id)
        guard status == "idle" || status == "terminated" else { return }
        let digest = SessionDigest(events: try await ManagedAgentsAPI.events(id))
        if let cost = digest.costCents { change(id) { $0.costCents = cost } }
        if digest.webSearches > 0 { change(id) { $0.webSearches = digest.webSearches } }
        guard let bot = store.bot(run.botID) else { return }
        // Built-in tools that paused for permission: only web search and fetch, and only for bots allowed the web.
        for ask in digest.confirmations {
            let allow = bot.usesWeb && (ask.name == "web_search" || ask.name == "web_fetch")
            do { try await ManagedAgentsAPI.confirm(id, toolUseID: ask.id, allow: allow) }
            catch let e as ManagedAgentsAPI.APIError where e.status == 400 || e.status == 409 {}
            if !allow { change(id) { $0.steps.append("Refused: \(ask.name)") } }
        }

        switch digest.outcome {
        case .working:
            return
        case .waitingForOrbit:
            var waiting = false
            for use in digest.pending where !run.answered.contains(use.id) {
                switch BotGate.decide(use.name, for: bot) {
                case .ask:
                    queue(use, run: run, reason: digest.messages.last)
                    waiting = true
                case .run, .runThenTell:
                    let (text, isError, step) = await execute(use, bot: bot, runID: id, trusted: BotGate.decide(use.name, for: bot) == .runThenTell)
                    try await answerSafely(id, use.id, text, isError)
                    change(id) { $0.answered.append(use.id); if let step { $0.steps.append(step) } }
                case .refuse(let why):
                    try await answerSafely(id, use.id, why, true)
                    change(id) { $0.answered.append(use.id); $0.steps.append("Refused: \(use.name)") }
                }
            }
            change(id) { $0.state = waiting ? .waiting : .working }
        case .finished:
            finish(id, state: .done, report: digest.report, error: digest.report == nil ? "The bot finished without writing anything." : nil)
        case .budgetReached:
            finish(id, state: .budget, report: digest.report, error: "Stopped at its spend cap of \(Self.dollars(bot.budgetCents)) for one run.")
        case .failed(let why):
            finish(id, state: .failed, report: digest.report, error: why)
        }
    }

    private func answerSafely(_ session: String, _ use: String, _ text: String, _ isError: Bool) async throws {
        do { try await ManagedAgentsAPI.answer(session, toolUseID: use, text: text, isError: isError) }
        catch let e as ManagedAgentsAPI.APIError where e.status == 400 || e.status == 409 {}
    }

    // MARK: ChatGPT runs on this Mac

    private func startLocal(_ bot: Bot, kind: BotRun.Kind, title: String, message: String,
                            link: (inout BotRun) -> Void) -> String? {
        guard OpenAIAPI.isConfigured else {
            lastError = "Add your OpenAI API key in Settings → Accounts → ChatGPT."
            return nil
        }
        var run = BotRun(id: "local-\(UUID().uuidString)", botID: bot.id, kind: kind, title: title, started: .now)
        run.provider = .chatgpt
        link(&run)
        runs.append(run)
        persist()
        let id = run.id
        // Runs in the background, so a bot handing work over doesn't wait for the other to finish.
        Task {
            do {
                let turn = try await OpenAIAPI.start(model: bot.model, instructions: Self.instructions(bot), message: message,
                                                     tools: bot.openAITools)
                apply(turn, to: id)
                lastError = nil
                await continueLocal(id)
            } catch {
                finish(id, state: .failed, report: nil, error: error.localizedDescription)
            }
        }
        return id
    }

    /// Records a response: its text, its tool calls and how many tokens it used.
    private func apply(_ turn: OpenAIAPI.Turn, to id: String) {
        change(id) {
            $0.responseID = turn.id
            $0.calls = turn.calls
            $0.outputs = [:]
            $0.messages = ($0.messages ?? []) + turn.texts
            $0.tokens = ($0.tokens ?? 0) + turn.inputTokens + turn.outputTokens
            $0.inputTokens = ($0.inputTokens ?? 0) + turn.inputTokens
            $0.outputTokens = ($0.outputTokens ?? 0) + turn.outputTokens
            if turn.webSearches > 0 { $0.webSearches = ($0.webSearches ?? 0) + turn.webSearches }
            let model = self.store.bot($0.botID)?.model ?? ""
            $0.costCents = Self.estimatedCents(model: model, input: $0.inputTokens ?? 0, output: $0.outputTokens ?? 0,
                                               searches: $0.webSearches ?? 0)
        }
        guard turn.calls.isEmpty else { return }
        let report = runs.first { $0.id == id }?.messages?.last
        if let error = turn.error {
            finish(id, state: .failed, report: report, error: error)
        } else {
            finish(id, state: .done, report: report, error: report == nil ? "The bot finished without writing anything." : nil)
        }
    }

    /// Answers the tool calls of the latest response and continues, until the run finishes or
    /// needs the user. At most 15 rounds per call, so a confused bot can't loop forever.
    private func continueLocal(_ id: String) async {
        guard !localBusy.contains(id) else { return }
        localBusy.insert(id)
        defer { localBusy.remove(id) }
        for _ in 0..<15 {
            guard let run = runs.first(where: { $0.id == id }), run.isOpen, let bot = store.bot(run.botID),
                  let responseID = run.responseID, let calls = run.calls, !calls.isEmpty else { return }
            var waiting = false
            for call in calls where run.outputs?[call.callID] == nil {
                let use = SessionDigest.ToolUse(id: call.callID, name: call.name, inputJSON: call.arguments)
                switch BotGate.decide(call.name, for: bot) {
                case .ask:
                    queue(use, run: run, reason: run.messages?.last)
                    waiting = true
                case .run, .runThenTell:
                    let (text, isError, step) = await execute(use, bot: bot, runID: id, trusted: BotGate.decide(call.name, for: bot) == .runThenTell)
                    change(id) {
                        $0.outputs = ($0.outputs ?? [:]).merging([call.callID: isError ? "Error: " + text : text]) { $1 }
                        if let step { $0.steps.append(step) }
                    }
                case .refuse(let why):
                    change(id) {
                        $0.outputs = ($0.outputs ?? [:]).merging([call.callID: "Refused: " + why]) { $1 }
                        $0.steps.append("Refused: \(call.name)")
                    }
                }
            }
            if waiting { change(id) { $0.state = .waiting }; return }
            guard let ready = runs.first(where: { $0.id == id }) else { return }
            let outputs = calls.map { (callID: $0.callID, output: ready.outputs?[$0.callID] ?? "No result.") }
            do {
                let turn = try await OpenAIAPI.resume(model: bot.model, instructions: Self.instructions(bot), previous: responseID,
                                                      outputs: outputs, tools: bot.openAITools)
                apply(turn, to: id)
            } catch {
                lastError = error.localizedDescription
                // Tried again on the next tick; gives up after 3 days like cloud runs.
                if ready.started < .now.addingTimeInterval(-3 * 86400) {
                    finish(id, state: .failed, report: ready.messages?.last, error: error.localizedDescription)
                }
                return
            }
        }
        finish(id, state: .failed, report: runs.first { $0.id == id }?.messages?.last, error: "The bot used too many steps and was stopped.")
    }

    /// Scheduled runs of ChatGPT bots: started when the time has come and the Mac is awake.
    /// A run missed while the Mac slept starts on wake, if it's less than 12 hours late.
    private func startDueLocalRuns(now: Date = .now) async {
        var last = UserDefaults.standard.dictionary(forKey: Self.lastLocalKey) as? [String: Double] ?? [:]
        var due: [(Bot, Date)] = []
        for bot in store.bots where bot.enabled && bot.engine == .chatgpt {
            guard let slot = bot.schedule.latest(atOrBefore: now) else { continue }
            let previous = last[bot.id].map { Date(timeIntervalSince1970: $0) }
            if previous == nil {
                // First time: remember the current slot so turning a bot on doesn't run it at once.
                last[bot.id] = slot.timeIntervalSince1970
                continue
            }
            guard Self.shouldStartLocal(due: slot, lastRun: previous, now: now), !isBusy(bot.id) else { continue }
            last[bot.id] = slot.timeIntervalSince1970
            due.append((bot, slot))
        }
        UserDefaults.standard.set(last, forKey: Self.lastLocalKey)
        for (bot, slot) in due {
            await start(bot.id, kind: .scheduled, title: Self.title(for: bot, at: slot), message: bot.kickoff)
        }
    }

    nonisolated static func shouldStartLocal(due: Date, lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return false }
        return due > lastRun && now.timeIntervalSince(due) < 12 * 3600
    }

    static func instructions(_ bot: Bot) -> String {
        UserProfile.fill(bot.job + "\n\n" + Bot.houseRules) + "\n\nIt is now \(OrbitTools.now())."
    }

    // MARK: Doing what the gate allows

    /// Runs an allowed tool for a bot: memory, a lookup, or a trusted change (recorded with Undo).
    private func execute(_ use: SessionDigest.ToolUse, bot: Bot, runID: String, trusted: Bool) async -> (String, Bool, String?) {
        switch use.name {
        case "recall_memory":
            return (memory.recall(bot.id), false, "Read its memory")
        case "remember":
            let text = use.input["text"] as? String ?? ""
            guard memory.add(text, for: bot.id, source: .bot) != nil else { return ("Nothing to remember.", true, nil) }
            return ("Remembered.", false, "Remembered: \(BotMemory.clean(text))")
        case "forget_memory":
            let ok = memory.delete(use.input["id"] as? String ?? "", botID: bot.id)
            return ok ? ("Forgotten.", false, "Forgot a note") : ("No note with that id.", true, nil)
        case "list_teammates":
            return (teammates(of: bot), false, "Looked at its teammates")
        default:
            break
        }
        let outcome = await performTool(use.name, use.input, botID: bot.id, runID: runID)
        guard trusted else { return (outcome.text, outcome.isError, Self.step(use)) }
        let title = ApprovalPresentation(tool: use.name, input: use.input).title
        guard !outcome.isError else { return (outcome.text, true, "Failed: \(title)") }
        let action = BotAction(id: UUID().uuidString, botID: bot.id, runID: runID, title: title, undo: outcome.undo, at: .now)
        actions.append(action)
        if actions.count > 100 { actions.removeFirst(actions.count - 100) }
        persistActions()
        onAction?(action)
        return (outcome.text + " (Done on its own because \(UserProfile.firstName) trusts you with this; they can undo it for 10 minutes.)", false, "Did on its own: \(title)")
    }

    /// Changes that need the runner (hand-offs) are done here; everything else by OrbitTools.
    private func performTool(_ name: String, _ input: [String: Any], botID: String, runID: String) async -> OrbitTools.Outcome {
        guard name == "hand_off" else { return await tools.perform(name, input) }
        guard let bot = store.bot(botID), let run = runs.first(where: { $0.id == runID }) else {
            return .init(text: "This run is gone.", isError: true)
        }
        return await handOff(from: bot, run: run, input: input)
    }

    // MARK: Teamwork

    /// The other bots that are switched on, for list_teammates.
    private func teammates(of bot: Bot) -> String {
        let others = store.bots.filter { $0.enabled && $0.id != bot.id }
        guard !others.isEmpty else { return "No other bots are switched on." }
        return others.map { "• \($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    /// The bots already in a run's hand-off chain (itself included), oldest first.
    func chain(of run: BotRun) -> [String] {
        var ids = [run.botID]
        var current = run
        while let parent = current.parentRunID, let next = runs.first(where: { $0.id == parent }), ids.count < 10 {
            ids.insert(next.botID, at: 0)
            current = next
        }
        return ids
    }

    /// At most this many hand-offs in a row (Inbox → Account Manager → one more).
    nonisolated static let maxHandoffDepth = 2

    nonisolated static func handOffProblem(to target: Bot?, from bot: Bot, chain: [String], depth: Int,
                                           overCap: Bool, teammateNames: [String]) -> String? {
        guard let target else {
            return teammateNames.isEmpty ? "No other bots are switched on." : "No teammate by that name. Switched on: \(teammateNames.joined(separator: ", "))."
        }
        if target.id == bot.id { return "You can't hand work to yourself." }
        if !target.enabled { return "\(target.name) is switched off." }
        if chain.contains(target.id) { return "\(target.name) already worked on this, so handing it back would go round in circles. Mention it in your report instead." }
        if depth > maxHandoffDepth { return "This task has been handed on \(maxHandoffDepth) times already. Mention it in your report instead." }
        if overCap { return "\(target.name) has used its monthly cap." }
        return nil
    }

    private func handOff(from bot: Bot, run: BotRun, input: [String: Any]) async -> OrbitTools.Outcome {
        let wanted = (input["to"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let task = (input["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let context = (input["context"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return .init(text: "Say what the other bot should do (task).", isError: true) }
        let others = store.bots.filter { $0.enabled && $0.id != bot.id }
        let target = store.bots.first { $0.name.lowercased() == wanted } ?? store.bots.first { !wanted.isEmpty && $0.name.lowercased().contains(wanted) }
        if let problem = Self.handOffProblem(to: target, from: bot, chain: chain(of: run), depth: (run.depth ?? 0) + 1,
                                              overCap: target.map(isOverCap) ?? false, teammateNames: others.map(\.name)) {
            return .init(text: problem, isError: true)
        }
        let to = target!
        let message = """
        \(bot.name) handed you this task:
        \(task)
        \(context.isEmpty ? "" : "\nWhat \(bot.name) found:\n\(context)\n")
        Handle it as part of your job, then report to \(UserProfile.firstName). Don't hand it back to \(bot.name).
        """
        let title = "From \(bot.name): \(String(task.prefix(60)))"
        guard let id = await startRun(to.id, kind: .handoff, title: title, message: message, parent: (run, task)) else {
            return .init(text: "Couldn't start \(to.name): \(lastError ?? "unknown error").", isError: true)
        }
        return .init(text: "Handed to \(to.name); it's working on it now and reports to \(UserProfile.firstName) itself. Don't repeat its work.",
                     isError: false, undo: .stopRun(id: id))
    }

    /// Stops a run (Undo of a hand-off, or Stop in the notch).
    func stop(_ runID: String) async {
        guard let run = runs.first(where: { $0.id == runID }), run.isOpen else { return }
        if run.engine == .claude {
            _ = try? await ManagedAgentsAPI.call("POST", "sessions/\(runID)/events", body: ["events": [["type": "user.interrupt"]]])
        }
        finish(runID, state: .failed, report: run.messages?.last, error: "You stopped this run.")
    }

    /// Takes back something a bot did on its own.
    func undo(_ actionID: String) async {
        guard let i = actions.firstIndex(where: { $0.id == actionID }), actions[i].canUndo(), let u = actions[i].undo else { return }
        if case .stopRun(let id) = u {
            await stop(id)
        } else if let problem = await tools.undo(u) {
            lastError = "Couldn't undo: \(problem)"
            return
        }
        actions[i].undone = true
        persistActions()
        let title = actions[i].title
        change(actions[i].runID) { $0.steps.append("You undid: \(title)") }
    }

    // MARK: Trust

    private func countApproval(botID: String, tool: String, plain: Bool) {
        var streaks = UserDefaults.standard.dictionary(forKey: Self.streakKey) as? [String: Int] ?? [:]
        let key = botID + "/" + tool
        streaks[key] = plain ? (streaks[key] ?? 0) + 1 : 0
        UserDefaults.standard.set(streaks, forKey: Self.streakKey)
        guard let bot = store.bot(botID),
              Self.shouldOffer(streak: streaks[key] ?? 0, tool: tool, bot: bot, declined: declined.contains(key),
                               alreadyOffered: trustOffers.contains { $0.id == key }) else { return }
        let offer = TrustOffer(botID: botID, tool: tool)
        trustOffers.append(offer)
        persistOffers()
        onTrustOffer?(offer)
    }

    nonisolated static func shouldOffer(streak: Int, tool: String, bot: Bot, declined: Bool, alreadyOffered: Bool) -> Bool {
        streak >= trustAfter && BotGate.trustable.contains(tool) && !bot.trustedTools.contains(tool)
            && bot.level == .draft && !declined && !alreadyOffered
    }

    /// the user's answer to a trust offer.
    func answer(_ offer: TrustOffer, yes: Bool) {
        trustOffers.removeAll { $0.id == offer.id }
        persistOffers()
        if yes {
            store.update(offer.botID) { bot in
                var t = Set(bot.trusted ?? [])
                t.insert(offer.tool)
                bot.trusted = Array(t).sorted()
            }
        } else {
            var d = declined
            d.insert(offer.id)
            UserDefaults.standard.set(Array(d), forKey: Self.declinedKey)
        }
    }

    private var declined: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }

    // MARK: Spend

    /// What a bot's runs cost this calendar month, in US cents.
    func spent(_ botID: String, now: Date = .now, calendar: Calendar = .current) -> Int {
        Self.spent(runs, botID: botID, now: now, calendar: calendar)
    }

    nonisolated static func spent(_ runs: [BotRun], botID: String, now: Date, calendar: Calendar = .current) -> Int {
        let month = calendar.dateInterval(of: .month, for: now)
        return runs.filter { $0.botID == botID && (month?.contains($0.started) ?? false) }.compactMap(\.costCents).reduce(0, +)
    }

    func isOverCap(_ bot: Bot) -> Bool { spent(bot.id) >= bot.monthlyCap }

    /// ChatGPT has no cost in its answers, so Orbit estimates it from OpenAI's list prices
    /// (US cents per million tokens, input / output).
    nonisolated static func estimatedCents(model: String, input: Int, output: Int, searches: Int = 0) -> Int {
        let prices: [String: (Double, Double)] = [
            "gpt-6-astra": (1000, 5000), "gpt-6.1-sol": (200, 1000), "gpt-6.1-terra": (100, 500), "gpt-6-luna": (10, 50),
        ]
        let (inPrice, outPrice) = prices[model] ?? (1000, 5000)
        // Web searches are billed per call; estimated at 2.5 ¢ each. Rounded up to whole cents,
        // so a run is never shown as free.
        return Int(((Double(input) * inPrice + Double(output) * outPrice) / 1_000_000 + Double(searches) * 2.5).rounded(.up))
    }

    // MARK: Helpers

    private func finish(_ id: String, state: BotRun.State, report: String?, error: String?) {
        change(id) { $0.state = state; $0.report = report; $0.error = error; $0.finished = .now }
        dropApprovals(for: id)
        if let run = runs.first(where: { $0.id == id }) { onReport?(run) }
    }

    private func dropApprovals(for runID: String) {
        guard approvals.contains(where: { $0.runID == runID }) else { return }
        approvals.removeAll { $0.runID == runID }
        persistApprovals()
    }

    private func change(_ id: String, _ edit: (inout BotRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        edit(&runs[i])
        persist()
    }

    private func prune() {
        guard runs.count > Self.keep else { return }
        let keep = Set(runs.filter(\.isOpen).map(\.id))
        let sorted = runs.sorted { $0.started > $1.started }
        runs = Array(sorted.prefix(Self.keep)) + sorted.dropFirst(Self.keep).filter { keep.contains($0.id) }
        persist()
    }

    private func persist() { if save { Storage.save(runs, to: Self.file) } }
    private func persistApprovals() { if save { Storage.save(approvals, to: Self.approvalsFile) } }
    private func persistActions() { if save { Storage.save(actions, to: Self.actionsFile) } }
    private func persistOffers() {
        if save, let data = try? JSONEncoder().encode(trustOffers) { UserDefaults.standard.set(data, forKey: Self.offersKey) }
    }

    static func title(for bot: Bot, at date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return bot.id == Bot.chiefOfStaff.id ? "Briefing · \(day)" : "\(bot.name) · \(day)"
    }

    /// "Looked at your day", for the run's history. Changes are recorded when the user decides.
    static func step(_ use: SessionDigest.ToolUse) -> String? {
        switch use.name {
        case "get_overview": return "Looked at your day"
        case "get_meeting": return "Read a meeting invite"
        case "lookup_contacts":
            let n = (use.input["emails"] as? [Any])?.count ?? 0
            return "Looked up \(n) \(n == 1 ? "person" : "people") in HubSpot"
        case "search_notes": return "Searched your notes"
        case "find_quiet_deals": return "Checked quiet deals"
        case "find_recent_replies": return "Checked customer replies"
        case "get_deal": return "Read a deal"
        case "find_emails": return "Checked your inbox"
        case "read_email": return "Read an email"
        case "list_teammates": return "Looked at its teammates"
        case "recall_memory": return "Read its memory"
        default: return ApprovalPresentation(tool: use.name, input: use.input).title
        }
    }

    static func dollars(_ cents: Int) -> String { String(format: "$%.2f", Double(cents) / 100) }
}
