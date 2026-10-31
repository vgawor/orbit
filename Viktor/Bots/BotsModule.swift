import SwiftUI

/// Bots: AI teammates that run in the cloud and come back to you in the notch.
/// Phase 1: Chief of Staff writes a morning briefing and preps meetings, read-only.
@MainActor
@Observable
final class BotsModule: NotchModule {
    let id = "bots"
    let title = "Bots"
    let symbol = "person.2.wave.2"

    let store: BotStore
    let runner: BotRunner
    /// Approvals on your phone (Orbit account).
    let phone: PhoneSync
    private let meetings: MeetingsModule
    private let alerts: AlertCenter
    private let openPanel: @MainActor (String) -> Void

    /// The panel's Team view (hand-offs between bots).
    static let teamID = "team"

    /// Which bot the panel shows.
    var selection: String = Bot.chiefOfStaff.id
    /// Which run's report is open in the panel (nil = the latest).
    var openRun: String?

    private var prepTimer: Timer?
    private var planTimer: Timer?
    private var lastUsesPro = OrbitCloud.shared.usesPro

    /// Refreshes the Orbit Pro status; when it starts or ends, bots move to the right keys.
    func refreshPlan() async {
        await OrbitCloud.shared.refreshStatus()
        let now = OrbitCloud.shared.usesPro
        if now != lastUsesPro {
            lastUsesPro = now
            await store.syncAll()
        }
    }
    private static let preppedKey = "bots.preppedMeetings"
    /// Minutes before a meeting that Chief of Staff starts its prep.
    nonisolated static let prepLead: TimeInterval = 10 * 60

    init(tools: OrbitTools, meetings: MeetingsModule, alerts: AlertCenter,
         openPanel: @escaping @MainActor (String) -> Void,
         store: BotStore? = nil, runner: BotRunner? = nil) {
        let store = store ?? BotStore()
        self.store = store
        let runner = runner ?? BotRunner(store: store, tools: tools)
        self.runner = runner
        self.phone = PhoneSync(runner: runner)
        self.meetings = meetings
        self.alerts = alerts
        self.openPanel = openPanel
        self.runner.onReport = { [weak self] run in self?.announce(run) }
        self.runner.onApproval = { [weak self] approval in
            self?.announce(approval)
            self?.phone.syncSoon()
        }
        self.runner.onAction = { [weak self] action in self?.announce(action) }
        self.runner.onTrustOffer = { [weak self] offer in self?.announce(offer) }
    }

    func start() {
        runner.start()
        phone.start()
        // Your plan decides whose keys bots use; check it now and every half hour.
        Task { await refreshPlan() }
        planTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshPlan() }
        }
        prepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prepIfDue() }
        }
    }

    func stop() {
        runner.stop()
        phone.stop()
        planTimer?.invalidate()
        planTimer = nil
        prepTimer?.invalidate()
        prepTimer = nil
    }

    var isConfigured: Bool { previewConfigured || ManagedAgentsAPI.isConfigured || OpenAIAPI.isConfigured }
    private var previewConfigured = false

    /// Layout snapshots only: a switched-on Chief of Staff with a briefing and a prep. Never syncs.
    func previewFill() {
        previewConfigured = true
        var chief = Bot.chiefOfStaff
        chief.enabled = true
        chief.agentID = "agent_preview"
        chief.agentVersion = 3
        var manager = Bot.accountManager
        manager.enabled = true
        store.previewSet([chief, manager])
        let now = Date.now
        var briefing = BotRun(id: "sesn_b", botID: chief.id, kind: .scheduled, title: "Briefing · Thu 29 Oct",
                              started: now.addingTimeInterval(-3600))
        briefing.state = .done
        briefing.costCents = 4
        briefing.report = """
        • 10:00 Acme with Dana Holm (CFO). Last time you promised pricing for 40 seats.
        • Overdue: send the case study to Nordbyrån (2 days).
        • Due today: sign the Q4 partner agreement.
        • Free from 14:00 to 16:30, good for Focus.
        Have a good Thursday, Sam.
        """
        briefing.steps = ["Looked at your day", "Read a meeting invite", "Looked up 1 person in HubSpot", "Searched your notes"]
        var prep = BotRun(id: "sesn_p", botID: chief.id, kind: .prep, title: "Prep · Nordbyrån check-in",
                          started: now.addingTimeInterval(-86400))
        prep.state = .done
        prep.read = true
        prep.costCents = 3
        prep.report = "• Anna Berg, marketing lead at Nordbyrån."
        var deals = BotRun(id: "sesn_d", botID: manager.id, kind: .scheduled, title: "Account Manager · Thu 29 Oct",
                           started: now.addingTimeInterval(-600))
        deals.state = .waiting
        deals.steps = ["Checked customer replies", "Checked quiet deals", "Read a deal"]
        let input: [String: Any] = ["to": ["dana.holm@acme.se"], "subject": "Re: Pricing 2027",
                                    "body": "Hi Dana,\n\nGreat to hear. Annual for 40 seats comes to 96 000 kr with onboarding included. I've attached the agreement, ready to sign.\n\nViktor"]
        let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let ask = BotApproval(id: "sevt_a", runID: deals.id, botID: manager.id, tool: "draft_email", inputJSON: json,
                              reason: "Acme replied on pricing and wants the annual plan for 40 seats. Here's a reply.", created: now.addingTimeInterval(-300))
        var inbox = BotGallery.inbox.makeBot(id: "bot-inbox")
        inbox.enabled = true
        store.previewSet([chief, manager, inbox])
        var handed = BotRun(id: "sesn_h", botID: manager.id, kind: .handoff, title: "From Inbox: Answer Maja at Lumen Studio",
                            started: now.addingTimeInterval(-900))
        handed.state = .done
        handed.read = true
        handed.parentRunID = "sesn_i"
        handed.fromBotID = inbox.id
        handed.depth = 1
        handed.handoffTask = "Maja at Lumen Studio asks whether hourly billing is still possible. Draft an answer for Sam."
        handed.report = "• Drafted a reply to Maja offering hourly billing at 1 590 kr/h."
        let did = BotAction(id: "act_1", botID: manager.id, runID: deals.id, title: "Create a task in HubSpot: “Call Maja at Lumen Studio”",
                            undo: .hubspotTask(id: "1", title: "Call Maja at Lumen Studio"), at: now.addingTimeInterval(-120))
        runner.previewSet([briefing, prep, deals, handed], approvals: [ask], actions: [did],
                          offers: [TrustOffer(botID: manager.id, tool: "hubspot_log_note")])
        runner.memory.previewSet([
            BotMemoryNote(id: "m1a2b3", botID: manager.id, text: "Acme only signs annual plans; Dana Holm (CFO) approves.", created: now, source: .bot),
            BotMemoryNote(id: "m4c5d6", botID: manager.id, text: "Sam signs emails with just “Sam” and keeps them under 80 words.", created: now, source: .bot),
            BotMemoryNote(id: "m7e8f9", botID: manager.id, text: "Never follow up with Lumen Studio before Maja is back from leave.", created: now, source: .you),
        ])
    }

    // MARK: Notch surfaces

    var runningCount: Int { runner.working.count }

    var peekView: AnyView? {
        let working = runner.working
        guard !working.isEmpty else { return nil }
        let bots = working.compactMap { store.bot($0.botID) }
        return AnyView(BotMoons(bots: Array(bots.prefix(3)), working: true))
    }
    var peekSide: PeekSide { .trailing }
    var peekPriority: Int { 1 }

    var peekChip: PeekChip? {
        if let ask = runner.approvals.first, let bot = store.bot(ask.botID) {
            let n = runner.approvals.count
            return PeekChip(symbol: "hand.raised.fill", text: n > 1 ? "\(n) bot requests need your OK" : "\(bot.name) needs your OK",
                            tint: Tokens.attention, priority: 6, target: id)
        }
        if let run = runner.unread.first, let bot = store.bot(run.botID) {
            return PeekChip(symbol: "sparkles", text: "\(bot.name) · \(run.kind == .prep ? "prep ready" : "report ready")",
                            tint: Appearance.companion(bot.color).body, priority: 3, target: id)
        }
        if let run = runner.working.first, let bot = store.bot(run.botID) {
            return PeekChip(symbol: "ellipsis", text: "\(bot.name) is working", tint: Tokens.secondary, priority: 1, target: id)
        }
        return nil
    }

    var attention: Attention? {
        if let ask = runner.approvals.first, let bot = store.bot(ask.botID) {
            return Attention(id: "bot-ask-\(ask.id)", symbol: "hand.raised", tint: Tokens.attention, label: bot.name,
                             priority: 4, headline: "\(bot.name) needs your OK")
        }
        guard let run = runner.unread.first, let bot = store.bot(run.botID) else { return nil }
        let what = run.state == .done ? (run.kind == .prep ? "prep is ready" : "report is ready") : "couldn't finish"
        return Attention(id: "bot-\(run.id)", symbol: "sparkles", tint: Appearance.companion(bot.color).body,
                         label: bot.name, priority: 2, headline: "\(bot.name): \(what)")
    }

    var homeCard: AnyView? {
        if let ask = runner.approvals.first {
            return AnyView(ApprovalCard(module: self, approval: ask, compact: true))
        }
        guard let run = runner.unread.first, store.bot(run.botID) != nil else { return nil }
        return AnyView(BotReportCard(module: self, run: run, compact: true))
    }

    var panel: AnyView { AnyView(BotsPanel(module: self)) }

    // MARK: Actions

    func toggle(_ botID: String, on: Bool) {
        store.update(botID) { $0.enabled = on }
        if on { runner.checkSoon(after: 8) }
    }

    func openPanelForBots() { openPanel(id) }

    func show(_ run: BotRun) {
        selection = run.botID
        openRun = run.id
        runner.markRead(run.id)
    }

    /// A change a bot made on its own: shown with Undo.
    private func announce(_ action: BotAction) {
        guard let bot = store.bot(action.botID) else { return }
        alerts.post(NotchAlert(
            symbol: "checkmark.circle.fill", tint: Appearance.companion(bot.color).body,
            title: "\(bot.name) did this on its own",
            subtitle: action.title,
            actions: action.undo == nil ? [] : [NotchAlert.Action(title: "Undo") { [weak self] in
                Task { await self?.runner.undo(action.id) }
            }],
            duration: 15))
    }

    /// "Let Account Manager create tasks on its own?"
    private func announce(_ offer: TrustOffer) {
        guard let bot = store.bot(offer.botID) else { return }
        alerts.post(NotchAlert(
            symbol: "hand.thumbsup.fill", tint: Appearance.companion(bot.color).body,
            title: "Let \(bot.name) \(Self.verb(offer.tool)) on its own?",
            subtitle: "You approved the last \(BotRunner.trustAfter) without changes.",
            actions: [NotchAlert.Action(title: "Review", isPrimary: true) { [weak self] in
                guard let self else { return }
                self.selection = offer.botID
                self.openPanel(self.id)
            }],
            duration: 12))
    }

    /// "create tasks", for trust offers and Settings.
    static func verb(_ tool: String) -> String {
        switch tool {
        case "create_task": "create tasks"
        case "add_note": "save notes in Orbit"
        case "hubspot_log_note": "log notes in HubSpot"
        case "hubspot_update_deal": "update deals in HubSpot"
        case "hand_off": "hand work to other bots"
        default: tool
        }
    }

    /// A bot asking for approval pops the notch open with Review.
    private func announce(_ approval: BotApproval) {
        guard let bot = store.bot(approval.botID) else { return }
        alerts.post(NotchAlert(
            symbol: "hand.raised.fill", tint: Tokens.attention,
            title: "\(bot.name) needs your OK",
            subtitle: ApprovalPresentation(tool: approval.tool, input: approval.input).title,
            actions: [NotchAlert.Action(title: "Review", isPrimary: true) { [weak self] in
                guard let self else { return }
                self.selection = approval.botID
                self.openPanel(self.id)
            }],
            duration: 12))
    }

    /// A finished report pops the notch open briefly, unless it's old news.
    private func announce(_ run: BotRun) {
        guard let bot = store.bot(run.botID), run.started > .now.addingTimeInterval(-12 * 3600) else { return }
        let first = run.report?.split(separator: "\n").first.map(String.init) ?? run.error ?? ""
        let what: String
        switch run.state {
        case .done: what = run.kind == .prep ? run.title : bot.id == Bot.chiefOfStaff.id && run.kind == .scheduled ? "your briefing is ready" : "report is ready"
        default: what = "couldn't finish"
        }
        alerts.post(NotchAlert(
            symbol: "sparkles", tint: run.state == .done ? Appearance.companion(bot.color).body : Tokens.attention,
            title: "\(bot.name): \(what)",
            subtitle: first.replacingOccurrences(of: "• ", with: ""),
            actions: [NotchAlert.Action(title: "Read", isPrimary: true) { [weak self] in
                guard let self else { return }
                self.show(run)
                self.openPanel(self.id)
            }],
            duration: 12))
    }

    // MARK: Meeting prep

    /// Starts Chief of Staff's prep about 10 minutes before a meeting with other people.
    func prepIfDue(now: Date = .now) {
        guard isConfigured, let bot = store.bot(Bot.chiefOfStaff.id), bot.enabled, bot.prepMeetings else { return }
        var prepped = Set(UserDefaults.standard.stringArray(forKey: Self.preppedKey) ?? [])
        for m in Self.meetingsToPrep(meetings.meetings, now: now, prepped: prepped) {
            prepped.insert(m.id)
            UserDefaults.standard.set(Array(prepped.suffix(200)), forKey: Self.preppedKey)
            let title = m.title.trimmingCharacters(in: .whitespaces)
            Task {
                await runner.start(bot.id, kind: .prep, title: "Prep · \(title)", message: """
                Prepare me for the meeting "\(title)" at \(m.start.formatted(.dateTime.hour().minute())) today.
                """)
            }
        }
    }

    /// Meetings with other people that start within the prep window and haven't been prepped.
    nonisolated static func meetingsToPrep(_ meetings: [Meeting], now: Date, prepped: Set<String>) -> [Meeting] {
        meetings.filter { shouldPrep(id: $0.id, start: $0.start, hasPeople: !$0.attendeeEmails.isEmpty, now: now, prepped: prepped) }
    }

    nonisolated static func shouldPrep(id: String, start: Date, hasPeople: Bool, now: Date, prepped: Set<String>) -> Bool {
        let lead = start.timeIntervalSince(now)
        return lead > 60 && lead <= prepLead && hasPeople && !prepped.contains(id)
    }
}
