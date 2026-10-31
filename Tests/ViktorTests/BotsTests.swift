import Foundation
import Testing
@testable import Viktor

@MainActor
struct BotsTests {
    // MARK: Reading a session's events

    private func use(_ id: String, _ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
        ["type": "agent.custom_tool_use", "id": id, "name": name, "input": input]
    }
    private func result(_ id: String) -> [String: Any] {
        ["type": "user.custom_tool_result", "custom_tool_use_id": id, "content": [["type": "text", "text": "ok"]]]
    }
    private func idle(_ reason: String) -> [String: Any] {
        ["type": "session.status_idle", "id": "sevt_idle", "stop_reason": ["type": reason]]
    }
    private func message(_ text: String) -> [String: Any] {
        ["type": "agent.message", "id": "sevt_m", "content": [["type": "text", "text": text]]]
    }

    @Test func toolCallsWaitUntilAnswered() {
        let events: [[String: Any]] = [
            ["type": "session.status_running"],
            use("sevt_1", "get_overview"),
            result("sevt_1"),
            use("sevt_2", "lookup_contacts", ["emails": ["dana@acme.se"]]),
            idle("requires_action"),
        ]
        let d = SessionDigest(events: events)
        #expect(d.outcome == .waitingForOrbit)
        #expect(d.pending.map(\.id) == ["sevt_2"])
        #expect(d.pending.first?.input["emails"] as? [String] == ["dana@acme.se"])
    }

    @Test func finishedRunKeepsTheLastMessageAsReport() {
        let events: [[String: Any]] = [
            message("Let me look at your day."),
            use("sevt_1", "get_overview"), result("sevt_1"),
            message("• 10:00 Acme with Dana\n• Send the case study"),
            ["type": "session.usage", "list_cost": ["amount": "7", "currency": "USD"]],
            idle("end_turn"),
        ]
        let d = SessionDigest(events: events)
        #expect(d.outcome == .finished)
        #expect(d.pending.isEmpty)
        #expect(d.report == "• 10:00 Acme with Dana\n• Send the case study")
        #expect(d.costCents == 7)
    }

    @Test func budgetAndFailuresAreReported() {
        #expect(SessionDigest(events: [idle("budget_reached")]).outcome == .budgetReached)
        let failed = SessionDigest(events: [
            ["type": "session.error", "error": ["message": "Model overloaded"]],
            idle("retries_exhausted"),
        ])
        #expect(failed.outcome == .failed("Model overloaded"))
        #expect(SessionDigest(events: [["type": "session.status_running"]]).outcome == .working)
        #expect(SessionDigest.cents(["amount": 12, "currency": "USD"]) == 12)
        #expect(SessionDigest.cents(nil) == nil)
    }

    // MARK: The safety gate

    @Test func gateOnlyLetsAllowedActionsThrough() {
        for level in BotLevel.allCases {
            #expect(BotGate.decide("get_overview", level: level) == .run)
            #expect(BotGate.decide("rm_rf", level: level) != .run)
            // Irreversible actions always ask, or are refused for read-only bots.
            #expect(BotGate.decide("send_email", level: level) != .run)
        }
        if case .refuse = BotGate.decide("create_task", level: .read) {} else { Issue.record("Read bots must not write") }
        #expect(BotGate.decide("create_task", level: .draft) == .ask)
        #expect(BotGate.decide("create_task", level: .doThenTell) == .runThenTell)
        #expect(BotGate.decide("create_task", level: .doQuietly) == .run)
        #expect(BotGate.decide("send_email", level: .doQuietly) == .ask)
    }

    // MARK: Schedules

    @Test func schedulesBecomeCronAndNextRun() {
        #expect(BotSchedule(days: .weekdays, hour: 8, minute: 0).cron == "0 8 * * 1-5")
        #expect(BotSchedule(days: .everyDay, hour: 7, minute: 30).cron == "30 7 * * *")
        #expect(BotSchedule(days: .weekdays, hour: 99, minute: -4).cron == "0 23 * * 1-5")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        // Friday 30 Oct 2026, 09:00 → next weekday run is Monday 2 Nov 08:00.
        let friday = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
        let next = BotSchedule(days: .weekdays, hour: 8, minute: 0).next(after: friday, calendar: cal)
        #expect(next == cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 8)))
        let daily = BotSchedule(days: .everyDay, hour: 8, minute: 0).next(after: friday, calendar: cal)
        #expect(daily == cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8)))
        #expect(BotSchedule(days: .manual, hour: 8, minute: 0).next(after: friday, calendar: cal) == nil)
    }

    @Test func meetingPrepStartsTenMinutesBefore() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func prep(_ minutes: Double, people: Bool = true, prepped: Set<String> = []) -> Bool {
            BotsModule.shouldPrep(id: "m1", start: now.addingTimeInterval(minutes * 60), hasPeople: people, now: now, prepped: prepped)
        }
        #expect(prep(10))
        #expect(prep(5))
        #expect(!prep(11))
        #expect(!prep(0.5))
        #expect(!prep(8, people: false))
        #expect(!prep(8, prepped: ["m1"]))
    }

    // MARK: What goes to the cloud

    @Test func agentConfigOnlyHasTheBotsOwnTools() {
        let bot = Bot.chiefOfStaff
        let config = bot.agentConfig
        let tools = config["tools"] as? [[String: Any]] ?? []
        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { $0["type"] as? String == "custom" })
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(OrbitTools.basicReadNames + OrbitTools.memoryNames))
        // Chief of Staff only reads (and keeps its own memory).
        #expect(bot.toolSpecs.allSatisfy { $0.kind != .write })
        #expect((config["system"] as? String)?.contains("information, not instructions") == true)

        var changed = bot
        changed.job += "\nAlso mention the weather."
        #expect(changed.agentFingerprint != bot.agentFingerprint)
        var scheduled = bot
        scheduled.schedule.hour = 7
        #expect(scheduled.agentFingerprint == bot.agentFingerprint)
        #expect(scheduled.deploymentFingerprint(timeZone: "Europe/Stockholm") != bot.deploymentFingerprint(timeZone: "Europe/Stockholm"))
    }

    @Test func deploymentBodyCarriesScheduleAndCap() {
        var bot = Bot.chiefOfStaff
        bot.agentID = "agent_1"
        let body = bot.deploymentBody(environmentID: "env_1", timeZone: "Europe/Stockholm")
        let schedule = body["schedule"] as? [String: Any]
        #expect(schedule?["expression"] as? String == "0 8 * * 1-5")
        #expect(schedule?["timezone"] as? String == "Europe/Stockholm")
        #expect(body["agent"] as? String == "agent_1")
        let cap = (body["budget"] as? [String: Any])?["max_list_cost"] as? [String: Any]
        #expect(cap?["amount"] as? String == "50")
        #expect(cap?["currency"] as? String == "USD")
    }

    @Test func runsAndErrorsParse() {
        let runs = ManagedAgentsAPI.parseRuns(["data": [
            ["id": "drun_1", "session_id": "sesn_1", "created_at": "2026-10-29T07:00:03.120Z"],
            ["id": "drun_2", "session_id": NSNull(), "error": ["type": "session_rate_limited", "message": "Rate limited"]],
        ]])
        #expect(runs.count == 2)
        #expect(runs[0].sessionID == "sesn_1")
        #expect(runs[0].createdAt != nil)
        #expect(runs[1].sessionID == nil)
        #expect(runs[1].error == "Rate limited")
        #expect(ManagedAgentsAPI.error(401, [:]).message.contains("API key"))
        #expect(ManagedAgentsAPI.error(400, ["error": ["message": "bad cron"]]).message == "bad cron")
    }

    @Test func storeAddsChiefOfStaffSwitchedOff() {
        let store = BotStore(bots: [], save: false)
        #expect(store.bots.map(\.id) == [Bot.chiefOfStaff.id, Bot.accountManager.id])
        #expect(store.bots.allSatisfy { !$0.enabled })
        #expect(store.bot(Bot.chiefOfStaff.id)?.level == .read)
        #expect(store.bot(Bot.accountManager.id)?.level == .draft)
    }

    @Test func stepsDescribeWhatTheBotLookedAt() {
        let lookup = SessionDigest.ToolUse(id: "1", name: "lookup_contacts", inputJSON: #"{"emails":["a@b.se","c@d.se"]}"#)
        #expect(BotRunner.step(lookup) == "Looked up 2 people in HubSpot")
        #expect(BotRunner.step(SessionDigest.ToolUse(id: "2", name: "get_overview", inputJSON: "{}")) == "Looked at your day")
        #expect(BotRunner.dollars(50) == "$0.50")
    }

    // MARK: Phase 2: approvals, Account Manager and ChatGPT

    @Test func gateChecksEachBotsOwnTools() {
        let chief = Bot.chiefOfStaff, manager = Bot.accountManager
        #expect(BotGate.decide("get_overview", for: chief) == .run)
        if case .refuse = BotGate.decide("create_task", for: chief) {} else { Issue.record("Chief of Staff can't create tasks") }
        if case .refuse = BotGate.decide("get_deal", for: chief) {} else { Issue.record("Chief of Staff has no deal tools") }
        #expect(BotGate.decide("get_deal", for: manager) == .run)
        for change in ["create_task", "hubspot_log_note", "hubspot_update_deal", "draft_email"] {
            #expect(BotGate.decide(change, for: manager) == .ask, "\(change) must wait for the user")
        }
        #expect(BotGate.decide("send_email", for: manager) == .ask)
        if case .refuse = BotGate.decide("delete_everything", for: manager) {} else { Issue.record("Unknown tools are refused") }
        var reader = manager
        reader.level = .read
        if case .refuse = BotGate.decide("draft_email", for: reader) {} else { Issue.record("Read level never changes things") }
    }

    @Test func toolsSpeakBothFormats() {
        let spec = OrbitTools.spec("draft_email")!
        #expect(spec.kind == .write)
        #expect(spec.anthropic["type"] as? String == "custom")
        #expect((spec.anthropic["input_schema"] as? [String: Any])?["required"] as? [String] == ["to", "subject", "body"])
        #expect(spec.openAI["type"] as? String == "function")
        #expect(spec.openAI["name"] as? String == "draft_email")
        #expect(spec.openAI["parameters"] != nil)
        // Every tool a built-in bot uses exists.
        for bot in [Bot.chiefOfStaff, Bot.accountManager] {
            #expect(bot.toolSpecs.count == bot.toolNames.count)
            #expect(bot.toolNames.count == Set(Bot.defaultTools(for: bot.id)).count)
        }
    }

    @Test func chatGPTRepliesParse() {
        let turn = OpenAIAPI.Turn([
            "id": "resp_1", "model": "gpt-6.1-sol", "status": "completed",
            "output": [
                ["type": "reasoning", "id": "rs_1"],
                ["type": "message", "content": [["type": "output_text", "text": "Checking your deals."]]],
                ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "get_deal", "arguments": #"{"deal_id":"42"}"#],
            ],
            "usage": ["input_tokens": 900, "output_tokens": 120],
        ])
        #expect(turn.id == "resp_1")
        #expect(turn.texts == ["Checking your deals."])
        #expect(turn.calls == [.init(callID: "call_1", name: "get_deal", arguments: #"{"deal_id":"42"}"#)])
        #expect(turn.inputTokens + turn.outputTokens == 1020)
        #expect(turn.error == nil)

        let cut = OpenAIAPI.Turn(["id": "resp_2", "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        #expect(cut.error?.contains("max_output_tokens") == true)
        #expect(OpenAIAPI.error(401, [:]).message.contains("API key"))
    }

    @Test func approvalsShowAndEditTheRequest() {
        let input: [String: Any] = ["to": ["dana@acme.se"], "subject": "Re: Pricing", "body": "Hi Dana"]
        var shown = ApprovalPresentation(tool: "draft_email", input: input)
        #expect(shown.title == "Draft an email to dana@acme.se")
        #expect(shown.action == "Open draft")
        #expect(shown.fields.map(\.key) == ["to", "subject", "body"])
        #expect(shown.edits(from: input).isEmpty)

        shown.fields[0].value = "dana@acme.se, anna@acme.se"
        shown.fields[2].value = "Hi Dana, thanks!"
        let edits = shown.edits(from: input)
        #expect(edits["to"] as? [String] == ["dana@acme.se", "anna@acme.se"])
        #expect(edits["body"] as? String == "Hi Dana, thanks!")
        #expect(edits["subject"] == nil)

        let deal = ApprovalPresentation(tool: "hubspot_update_deal", input: ["deal_id": "42", "dealstage": "contractsent"])
        #expect(deal.title == "Update deal 42: stage → contractsent")
        #expect(ApprovalPresentation(tool: "create_task", input: ["title": "Call Dana", "target": "hubspot"]).title == "Create a task in HubSpot: “Call Dana”")
    }

    @Test func chatGPTSchedulesRunOnTheMac() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        // Sunday 1 Nov 2026, 10:00 → the last weekday 09:00 run was Friday 30 Oct.
        let sunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10))!
        let latest = BotSchedule(days: .weekdays, hour: 9, minute: 0).latest(atOrBefore: sunday, calendar: cal)
        #expect(latest == cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9)))
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 30))!
        let slot = BotSchedule(days: .weekdays, hour: 9, minute: 0).latest(atOrBefore: monday, calendar: cal)!
        #expect(slot == cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))

        let friday = latest!
        #expect(BotRunner.shouldStartLocal(due: slot, lastRun: friday, now: monday))
        #expect(!BotRunner.shouldStartLocal(due: slot, lastRun: slot, now: monday), "never twice for one slot")
        #expect(!BotRunner.shouldStartLocal(due: slot, lastRun: nil, now: monday), "not right after turning on")
        #expect(!BotRunner.shouldStartLocal(due: slot, lastRun: friday, now: slot.addingTimeInterval(13 * 3600)), "too late")
    }

    @Test func botsSavedByTheLastVersionStillLoad() throws {
        // A bot and a run as Orbit 0.3 saved them, before providers, tools and approvals existed.
        let oldBot = #"[{"id":"chief-of-staff","name":"Chief of Staff","color":"sunny","summary":"s","job":"j","kickoff":"k","schedule":{"days":"weekdays","hour":8,"minute":0},"model":"claude-sonnet-5-5","level":"read","enabled":true,"prepMeetings":true,"budgetCents":50,"agentID":"agent_1"}]"#
        let bots = try JSONDecoder().decode([Bot].self, from: Data(oldBot.utf8))
        #expect(bots.first?.engine == .claude)
        #expect(bots.first?.agentID == "agent_1")
        #expect(bots.first?.toolNames == OrbitTools.basicReadNames + OrbitTools.memoryNames)
        #expect(bots.first?.monthlyCap == 2000)
        #expect(bots.first?.trustedTools.isEmpty == true)

        let oldRun = #"[{"id":"sesn_1","botID":"chief-of-staff","kind":"scheduled","title":"Briefing","started":800000000,"state":"done","read":false,"answered":[],"steps":[]}]"#
        let runs = try JSONDecoder().decode([BotRun].self, from: Data(oldRun.utf8))
        #expect(runs.first?.engine == .claude)
        #expect(runs.first?.isOpen == false)
    }

    @Test func switchingProviderPicksThatProvidersModel() {
        let store = BotStore(bots: [Bot.accountManager], save: false)
        store.setProvider(Bot.accountManager.id, .chatgpt)
        #expect(store.bot(Bot.accountManager.id)?.engine == .chatgpt)
        #expect(store.bot(Bot.accountManager.id)?.model == BotProvider.chatgpt.defaultModel)
        store.setProvider(Bot.accountManager.id, .claude)
        #expect(BotProvider.claude.models.map(\.id).contains(store.bot(Bot.accountManager.id)!.model))
    }

    // MARK: Phase 3: memory, trust, Undo and spend

    @Test func memoryAndTrustPassTheGate() {
        var manager = Bot.accountManager
        for tool in OrbitTools.memoryNames {
            #expect(BotGate.decide(tool, for: manager) == .run)
            #expect(BotGate.decide(tool, for: Bot.chiefOfStaff) == .run, "every bot has a memory")
        }
        #expect(BotGate.decide("create_task", for: manager) == .ask)
        manager.trusted = ["create_task", "draft_email"]
        #expect(BotGate.decide("create_task", for: manager) == .runThenTell)
        #expect(BotGate.decide("draft_email", for: manager) == .ask, "email drafts always ask")
        #expect(BotGate.decide("hubspot_log_note", for: manager) == .ask)
        manager.level = .read
        if case .refuse = BotGate.decide("create_task", for: manager) {} else { Issue.record("Read level overrides trust") }
    }

    @Test func memoryKeepsShortUniqueNotes() {
        let memory = BotMemory(save: false)
        let id = memory.add("Acme only signs annual plans.", for: "am", source: .bot)
        #expect(id != nil)
        #expect(memory.add("acme only signs annual plans.", for: "am", source: .bot) == id, "no duplicates")
        #expect(memory.add("   ", for: "am", source: .bot) == nil)
        #expect(memory.add(String(repeating: "x", count: 500), for: "am", source: .bot).flatMap { i in memory.notes.first { $0.id == i } }?.text.count == BotMemory.maxLength)
        memory.add("Sam's own note", for: "am", source: .you)
        for i in 0..<BotMemory.limit { memory.add("fact \(i)", for: "am", source: .bot) }
        #expect(memory.notes(for: "am").count == BotMemory.limit)
        #expect(memory.notes(for: "am").contains { $0.text == "Sam's own note" }, "your notes are kept when it's full")
        #expect(memory.recall("am").contains("(written by "))
        #expect(memory.recall("other") == "Nothing remembered yet.")

        let note = memory.notes(for: "am").last!
        #expect(!memory.delete(note.id, botID: "someone-else"), "a bot can only forget its own notes")
        memory.update(note.id, text: "")
        #expect(memory.notes.contains { $0.id == note.id }, "clearing the text doesn't delete")
        #expect(memory.delete(note.id, botID: "am"))
    }

    @Test func trustIsOfferedAfterPlainApprovals() {
        let manager = Bot.accountManager
        #expect(BotRunner.shouldOffer(streak: 10, tool: "create_task", bot: manager, declined: false, alreadyOffered: false))
        #expect(!BotRunner.shouldOffer(streak: 9, tool: "create_task", bot: manager, declined: false, alreadyOffered: false))
        #expect(!BotRunner.shouldOffer(streak: 12, tool: "draft_email", bot: manager, declined: false, alreadyOffered: false))
        #expect(!BotRunner.shouldOffer(streak: 12, tool: "create_task", bot: manager, declined: true, alreadyOffered: false))
        #expect(!BotRunner.shouldOffer(streak: 12, tool: "create_task", bot: manager, declined: false, alreadyOffered: true))
        var trusting = manager
        trusting.trusted = ["create_task"]
        #expect(!BotRunner.shouldOffer(streak: 12, tool: "create_task", bot: trusting, declined: false, alreadyOffered: false))
    }

    @Test func undoWindowAndRecordsRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let action = BotAction(id: "a", botID: "am", runID: "r", title: "Log a note", undo: .deal(id: "42", old: ["dealstage": "qualified"]), at: at)
        #expect(action.canUndo(now: at.addingTimeInterval(9 * 60)))
        #expect(!action.canUndo(now: at.addingTimeInterval(11 * 60)))
        var undone = action
        undone.undone = true
        #expect(!undone.canUndo(now: at))
        let back = try JSONDecoder().decode(BotAction.self, from: JSONEncoder().encode(action))
        #expect(back == action)
    }

    @Test func spendIsCountedPerMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        func run(_ day: Int, _ month: Int, _ cents: Int, bot: String = "am") -> BotRun {
            var r = BotRun(id: UUID().uuidString, botID: bot, kind: .scheduled, title: "", started: cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!)
            r.costCents = cents
            return r
        }
        let runs = [run(3, 11, 40), run(20, 11, 60), run(30, 10, 500), run(5, 11, 999, bot: "cos")]
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        #expect(BotRunner.spent(runs, botID: "am", now: now, calendar: cal) == 100)
        #expect(BotRunner.estimatedCents(model: "gpt-6.1-sol", input: 1_000_000, output: 100_000) == 300)
        #expect(BotRunner.estimatedCents(model: "gpt-6.1-terra", input: 1000, output: 200) == 1, "rounded up, never free")
        #expect(BotRunner.estimatedCents(model: "x", input: 0, output: 0) == 0)
        #expect(Bot.accountManager.monthlyCap == 2000)
    }

    @Test func everyBotGetsAMemory() {
        for bot in [Bot.chiefOfStaff, Bot.accountManager] {
            #expect(Set(OrbitTools.memoryNames).isSubset(of: Set(bot.toolNames)))
        }
        #expect(OrbitTools.spec("remember")?.kind == .memory)
        #expect(Bot.houseRules.contains("recall_memory"))
        // Saving a bot with trust and a cap, then reading it back.
        var bot = Bot.accountManager
        bot.trusted = ["create_task"]
        bot.monthlyCapCents = 1500
        let back = try? JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(back?.trustedTools == ["create_task"])
        #expect(back?.monthlyCap == 1500)
    }

    // MARK: Phase 4: your own bots, gallery, mail and web

    @Test func weeklySchedulesRunOnTheirDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let friday = BotSchedule(days: .weekly, hour: 16, minute: 0, weekday: 6)
        #expect(friday.cron == "0 16 * * 5")
        #expect(BotSchedule(days: .weekly, hour: 7, minute: 30).cron == "30 7 * * 1", "Monday when no day is set")
        // Thursday 29 Oct 2026 → next Friday run is 30 Oct 16:00; the last one was 23 Oct.
        let thursday = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
        #expect(friday.next(after: thursday, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 16)))
        #expect(friday.latest(atOrBefore: thursday, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 16)))
    }

    @Test func galleryBotsAreSafeAndComplete() {
        var ids = Set<String>()
        for t in BotGallery.templates {
            let bot = t.makeBot()
            #expect(!bot.enabled, "\(t.name) starts switched off")
            #expect(ids.insert(bot.id).inserted)
            #expect(Set(OrbitTools.memoryNames).isSubset(of: Set(bot.toolNames)))
            for tool in t.tools {
                #expect(OrbitTools.spec(tool) != nil || tool == Bot.webTool, "\(t.name) uses a real tool: \(tool)")
            }
            let changes = bot.toolNames.contains { BotGate.kind(of: $0) == .write }
            #expect(changes == (bot.level == .draft), "\(t.name): bots that change things ask first; read-only bots only read")
            #expect(!bot.isBuiltIn)
        }
        #expect(BotGallery.blank().level == .read)
        // Every tool in the editor exists.
        for group in BotGallery.toolGroups {
            for tool in group.tools { #expect(OrbitTools.spec(tool.name) != nil || tool.name == Bot.webTool) }
        }
    }

    @Test func webResearchUsesEachProvidersOwnSearch() {
        let scout = BotGallery.talentScout.makeBot()
        #expect(scout.usesWeb)
        #expect(!scout.toolSpecs.contains { $0.name == Bot.webTool }, "Orbit never answers web calls itself")
        let claudeTools = scout.agentConfig["tools"] as? [[String: Any]] ?? []
        let toolset = claudeTools.first { $0["type"] as? String == "agent_toolset_20260401" }
        let enabled = (toolset?["configs"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool == true }.compactMap { $0["name"] as? String }
        #expect(Set(enabled) == ["web_search", "web_fetch"])
        #expect(((toolset?["default_config"] as? [String: Any])?["enabled"] as? Bool) == false, "shell and files stay off")
        #expect(scout.openAITools.contains { $0["type"] as? String == "web_search" })
        #expect(!Bot.chiefOfStaff.usesWeb)
        #expect(!(Bot.chiefOfStaff.agentConfig["tools"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "agent_toolset_20260401" })

        let digest = SessionDigest(events: [
            ["type": "agent.tool_use", "id": "sevt_1", "name": "web_search", "evaluated_permission": "allow"],
            ["type": "agent.tool_use", "id": "sevt_2", "name": "web_fetch", "evaluated_permission": "ask"],
            ["type": "agent.tool_use", "id": "sevt_3", "name": "bash", "evaluated_permission": "ask"],
            ["type": "user.tool_confirmation", "tool_use_id": "sevt_3", "result": "deny"],
            ["type": "session.status_idle", "stop_reason": ["type": "requires_action"]],
        ])
        #expect(digest.webSearches == 2)
        #expect(digest.confirmations.map(\.id) == ["sevt_2"])
        #expect(digest.outcome == .waitingForOrbit)

        let turn = OpenAIAPI.Turn(["id": "r", "output": [["type": "web_search_call", "id": "ws_1", "status": "completed"],
                                                         ["type": "message", "content": [["type": "output_text", "text": "Found 5."]]]]])
        #expect(turn.webSearches == 1)
        #expect(BotRunner.estimatedCents(model: "gpt-6.1-sol", input: 0, output: 0, searches: 4) == 10)
    }

    @Test func appleMailListsParse() {
        let f = "\u{1F}", r = "\u{1E}"
        let text = ["101\(f)Dana Holm <dana@acme.se>\(f)Re: Pricing\(f)3600\(f)false",
                    "102\(f)News <news@x.com>\(f)Weekly digest\(f)90000\(f)true",
                    "broken row"].joined(separator: r)
        let list = AppleMail.parse(text)
        #expect(list.count == 2)
        #expect(list[0] == .init(id: "101", sender: "Dana Holm <dana@acme.se>", subject: "Re: Pricing", age: 3600, read: false))
        #expect(list[1].read)
        #expect(AppleMail.ago(3600) == "1 h ago")
        #expect(AppleMail.ago(90000) == "1 d ago")
        #expect(AppleMail.ago(20) == "1 min ago")
        #expect(AppleMail.MailError.notAllowed.message.contains("Automation"))
    }

    @Test func yourOwnBotsCanBeAddedAndRemoved() async {
        let store = BotStore(bots: [], save: false)
        let scout = BotGallery.talentScout.makeBot()
        store.add(scout)
        #expect(store.bot(scout.id) != nil)
        await store.remove(Bot.chiefOfStaff.id)
        #expect(store.bot(Bot.chiefOfStaff.id) != nil, "built-in bots can only be turned off")
        await store.remove(scout.id)
        #expect(store.bot(scout.id) == nil)
    }

    // MARK: Phase 5: bots working together

    @Test func handOffsAskFirstAndCanBeTrusted() {
        var manager = Bot.accountManager
        #expect(manager.toolNames.contains("hand_off"))
        #expect(BotGate.decide("list_teammates", for: manager) == .run)
        #expect(BotGate.decide("hand_off", for: manager) == .ask)
        manager.trusted = ["hand_off"]
        #expect(BotGate.decide("hand_off", for: manager) == .runThenTell)
        if case .refuse = BotGate.decide("hand_off", for: Bot.chiefOfStaff) {} else { Issue.record("Chief of Staff can't hand off") }
        #expect(BotGallery.inbox.tools.contains("hand_off"))

        let shown = ApprovalPresentation(tool: "hand_off", input: ["to": "Account Manager", "task": "Answer Maja", "context": "She asked about hourly billing."])
        #expect(shown.title == "Hand to Account Manager: Answer Maja")
        #expect(shown.action == "Hand over")
        #expect(shown.fields.map(\.key) == ["task", "context"])
    }

    @Test func handOffsCantLoopOrGoOnForever() {
        var inbox = BotGallery.inbox.makeBot(id: "inbox")
        inbox.enabled = true
        var manager = Bot.accountManager
        manager.enabled = true
        func problem(_ target: Bot?, chain: [String] = ["inbox"], depth: Int = 1, overCap: Bool = false) -> String? {
            BotRunner.handOffProblem(to: target, from: inbox, chain: chain, depth: depth, overCap: overCap, teammateNames: ["Account Manager"])
        }
        #expect(problem(manager) == nil)
        #expect(problem(nil)?.contains("Account Manager") == true, "names the teammates when the name is wrong")
        #expect(problem(inbox) != nil, "not to itself")
        #expect(problem(manager, chain: ["account-manager", "inbox"]) != nil, "never back to a bot in the chain")
        #expect(problem(manager, depth: BotRunner.maxHandoffDepth + 1) != nil, "stops after two hand-offs")
        #expect(problem(manager, overCap: true) != nil)
        var off = manager
        off.enabled = false
        #expect(problem(off) != nil, "not to a bot that's switched off")
    }

    @Test func handOffUndoAndRunsRoundTrip() throws {
        let action = BotAction(id: "a", botID: "inbox", runID: "r1", title: "Hand to Account Manager: Answer Maja",
                               undo: .stopRun(id: "sesn_2"), at: .now)
        #expect(try JSONDecoder().decode(BotAction.self, from: JSONEncoder().encode(action)) == action)
        var run = BotRun(id: "sesn_2", botID: "account-manager", kind: .handoff, title: "From Inbox: Answer Maja", started: .now)
        run.parentRunID = "r1"
        run.fromBotID = "inbox"
        run.depth = 1
        run.handoffTask = "Answer Maja"
        let back = try JSONDecoder().decode(BotRun.self, from: JSONEncoder().encode(run))
        #expect(back == run)
        #expect(back.kind == .handoff)
    }

    // MARK: Only your own deals

    @Test func onlyYourOwnDealsCount() {
        let mine: [String: Any] = ["id": "1", "properties": ["hubspot_owner_id": "555"]]
        let theirs: [String: Any] = ["id": "2", "properties": ["hubspot_owner_id": "777"]]
        let nobody: [String: Any] = ["id": "3", "properties": [String: Any]()]
        let numeric: [String: Any] = ["id": "4", "properties": ["hubspot_owner_id": 555]]
        #expect(HubSpotTaskProvider.isOwned(mine, by: "555"))
        #expect(!HubSpotTaskProvider.isOwned(theirs, by: "555"))
        #expect(!HubSpotTaskProvider.isOwned(nobody, by: "555"))
        #expect(HubSpotTaskProvider.isOwned(numeric, by: "555"))
        #expect(!HubSpotTaskProvider.isOwned(mine, by: ""), "no owner known means nothing counts as yours")
        #expect(HubSpotTaskProvider.dealProperties.contains("hubspot_owner_id"))
        #expect(Bot.houseRules.contains("deal owner"))
    }
}
