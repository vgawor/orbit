import SwiftUI

/// Small Orbits in each working bot's colour, for the peek.
struct BotMoons: View {
    let bots: [Bot]
    var working = false
    var body: some View {
        HStack(spacing: -2) {
            ForEach(bots) { bot in
                OrbitView(size: 18, motion: working ? .working : .still, colors: Appearance.companion(bot.color))
            }
        }
    }
}

/// The Bots tab: your bots on the left, the selected bot's requests and reports on the right.
struct BotsPanel: View {
    @Bindable var module: BotsModule
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sidebar.frame(width: 214)
            Group {
                if !module.isConfigured {
                    setup
                } else if module.selection == BotsModule.teamID {
                    TeamActivity(module: module)
                } else if let bot = module.store.bot(module.selection) {
                    BotDetail(module: module, bot: bot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            // Open on the bot that needs you.
            if let first = module.runner.approvals.first, module.runner.approvals(for: module.selection).isEmpty {
                module.selection = first.botID
            }
            module.runner.checkSoon()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchScroll {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(module.store.bots) { bot in row(bot) }
                    if !module.runner.handoffs.isEmpty { teamRow }
                }
            }
            Spacer(minLength: 0)
            Button {
                UserDefaults.standard.set(true, forKey: BotsSettings.galleryKey)
                SettingsView.show(.bots)
                SettingsWindow.willOpen()
                openSettings()
            } label: {
                Label("Add a bot", systemImage: "plus.circle").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            Button {
                SettingsView.show(.bots)
                SettingsWindow.willOpen()
                openSettings()
            } label: {
                Label("Bot settings", systemImage: "gearshape").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(24)
    }

    private func row(_ bot: Bot) -> some View {
        let selected = module.selection == bot.id
        let asks = module.runner.approvals(for: bot.id).count
        let unread = module.runner.unread.contains { $0.botID == bot.id }
        let working = module.runner.working.contains { $0.botID == bot.id }
        return Button { module.selection = bot.id; module.openRun = nil } label: {
            HStack(spacing: 9) {
                OrbitView(size: 30, mood: bot.enabled ? .normal : .closed, motion: asks > 0 ? .nudge : working ? .working : .still,
                          tint: Tokens.attention, colors: Appearance.companion(bot.color))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(bot.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if asks > 0 || unread {
                            Circle().fill(asks > 0 ? Tokens.attention : Appearance.companion(bot.color).body).frame(width: 6, height: 6)
                        }
                    }
                    Text(asks > 0 ? "Needs your OK (\(asks))" : BotDetail.status(bot, module: module)).font(.system(size: 11))
                        .foregroundStyle(asks > 0 ? Tokens.attention : Tokens.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Tokens.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var teamRow: some View {
        let selected = module.selection == BotsModule.teamID
        let working = module.runner.handoffs.filter(\.isOpen).count
        return Button { module.selection = BotsModule.teamID } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 14))
                    .foregroundStyle(Tokens.secondary).frame(width: 32, height: 32).glassSurface(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Team").font(.system(size: 12.5, weight: .semibold))
                    Text(working > 0 ? "\(working) handed-off task\(working == 1 ? "" : "s") running" : "Who handed what to whom")
                        .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Tokens.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                OrbitView(size: 40, motion: .still, colors: Appearance.companion("sunny"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bots work for you in the background").font(.system(size: 14, weight: .semibold))
                    Text("They run on a schedule and come back to you here. Changes wait for your OK.")
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Add an Anthropic API key (Claude, runs in the cloud) or an OpenAI API key (ChatGPT, runs on this Mac) in Settings → Accounts. Use keys with a monthly spend limit.")
                .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GlassPillButton(title: "Open Settings", symbol: "gearshape") {
                SettingsView.show(.accounts)
                SettingsWindow.willOpen()
                openSettings()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }
}

/// One bot: what waits for you, the latest report and earlier runs.
struct BotDetail: View {
    let module: BotsModule
    let bot: Bot

    private var runs: [BotRun] { module.runner.runs(for: bot.id) }
    private var asks: [BotApproval] { module.runner.approvals(for: bot.id) }
    private var shown: BotRun? {
        module.openRun.flatMap { id in runs.first { $0.id == id } } ?? runs.first { !$0.isOpen } ?? runs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = module.store.syncErrors[bot.id] ?? module.runner.lastError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NotchScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(module.runner.trustOffers.filter { $0.botID == bot.id }) { TrustOfferCard(module: module, offer: $0) }
                    ForEach(asks) { ApprovalCard(module: module, approval: $0, compact: false) }
                    OnItsOwnList(module: module, botID: bot.id)
                    if !bot.enabled && runs.isEmpty {
                        intro
                    } else if let run = shown {
                        BotReportCard(module: module, run: run, compact: false)
                        if runs.count > 1 { earlier }
                    } else if asks.isEmpty {
                        Text("No runs yet. \(bot.schedule.label), or press Run now.")
                            .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.system(size: 15, weight: .semibold))
                Text("\(bot.summary) · \(bot.engine.short) · \(bot.level.label)").font(.system(size: 11.5))
                    .foregroundStyle(Tokens.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if bot.enabled {
                let busy = module.runner.isBusy(bot.id)
                let working = busy && asks.isEmpty
                GlassPillButton(title: working ? "Working…" : "Run now", symbol: "play.fill") {
                    Task { await module.runner.runNow(bot.id) }
                }
                .disabled(working)
                .help(busy && !asks.isEmpty ? "Starts a fresh run and closes the one waiting for you" : "")
            }
            Toggle("", isOn: Binding(get: { bot.enabled }, set: { module.toggle(bot.id, on: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(bot.enabled ? "Turn \(bot.name) off" : "Turn \(bot.name) on")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.introText(bot))
                .font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(bot.engine == .claude
                 ? "Each run costs a few cents and stops at \(BotRunner.dollars(bot.budgetCents))."
                 : "Runs with ChatGPT on this Mac; usage is billed to your OpenAI key.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.faint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
    }

    static func introText(_ bot: Bot) -> String {
        switch bot.id {
        case Bot.chiefOfStaff.id:
            return "Turn on Chief of Staff for a short briefing every weekday at 08:00, and a prep 10 minutes before meetings with other people. It only reads your calendar, tasks, notes and HubSpot contacts; it never changes anything."
        case Bot.accountManager.id:
            return "Turn on Account Manager to go through your HubSpot deals every weekday at 09:00. It finds customer replies and deals that went quiet, and drafts follow-ups, tasks and notes. Nothing happens until you press Send in the notch, and emails only open as drafts in your mail app."
        default:
            let changes = bot.toolNames.contains { BotGate.kind(of: $0) == .write }
            return "\(bot.summary). Turn it on to start (\(bot.schedule.label)). " +
                (changes ? "Changes it suggests wait for your OK in the notch." : "It only reads; it never changes anything.")
        }
    }

    private var earlier: some View {
        VStack(alignment: .leading, spacing: 2) {
            CardLabel("Earlier")
            ForEach(runs.filter { $0.id != shown?.id }.prefix(4)) { run in
                Button { module.show(run) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Self.color(run)).frame(width: 6, height: 6)
                        Text(run.title).font(.system(size: 11.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(run.started.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func color(_ run: BotRun) -> Color {
        switch run.state {
        case .working: Tokens.secondary
        case .waiting: Tokens.attention
        case .done: Tokens.live
        case .failed, .budget: Tokens.attention
        }
    }

    /// One line for the bot list: what it's doing or when it runs next.
    static func status(_ bot: Bot, module: BotsModule) -> String {
        if module.runner.working.contains(where: { $0.botID == bot.id }) { return "Working…" }
        if !bot.enabled { return "Off" }
        if module.runner.isOverCap(bot) { return "Paused · monthly cap reached" }
        if module.store.syncing.contains(bot.id) { return "Setting up…" }
        if let next = bot.schedule.next(after: .now) {
            let cal = Calendar.current
            let time = next.formatted(.dateTime.hour().minute())
            if cal.isDateInToday(next) { return "Next: today \(time)" }
            if cal.isDateInTomorrow(next) { return "Next: tomorrow \(time)" }
            return "Next: \(next.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "When you ask"
    }
}

/// A change a bot wants to make: why, what exactly, and Send / Edit / Skip.
struct ApprovalCard: View {
    let module: BotsModule
    let approval: BotApproval
    var compact: Bool

    @State private var editing = false
    @State private var shown: ApprovalPresentation

    init(module: BotsModule, approval: BotApproval, compact: Bool) {
        self.module = module
        self.approval = approval
        self.compact = compact
        _shown = State(initialValue: ApprovalPresentation(tool: approval.tool, input: approval.input))
    }

    private var bot: Bot? { module.store.bot(approval.botID) }
    private var busy: Bool { module.runner.deciding.contains(approval.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let bot {
                    OrbitView(size: 28, motion: .nudge, tint: Tokens.attention, colors: Appearance.companion(bot.color))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(bot?.name ?? "A bot") needs your OK").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                    Text(shown.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(approval.created.formatted(.dateTime.hour().minute())).font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                    .lineLimit(compact ? 2 : 4).fixedSize(horizontal: false, vertical: true)
            }
            if editing {
                ForEach($shown.fields) { $field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.faint)
                        if field.multiline {
                            TextEditor(text: $field.value)
                                .font(.system(size: 12)).scrollContentBackground(.hidden)
                                .frame(minHeight: 70, maxHeight: 140)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.surface))
                        } else {
                            TextField(field.label, text: $field.value)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.surface))
                        }
                    }
                }
            } else {
                preview
            }
            HStack(spacing: 8) {
                Button {
                    let edits = shown.edits(from: approval.input)
                    Task { await module.runner.decide(approval.id, approve: true, edited: edits.isEmpty ? nil : edits) }
                } label: {
                    HStack(spacing: 5) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(shown.action)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(.white)).foregroundStyle(.black)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                if !shown.fields.isEmpty {
                    Button(editing ? "Done" : "Edit") {
                        if compact { module.selection = approval.botID; module.openPanelForBots() } else { editing.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Tokens.surface2))
                }
                Button("Skip") { Task { await module.runner.decide(approval.id, approve: false) } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.secondary)
                    .padding(.horizontal, 8).frame(height: 28)
                Spacer(minLength: 0)
            }
            .disabled(busy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.attention.opacity(0.35)))
        .glassCard(18)
    }

    /// The request as the user will approve it.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown.fields.filter { !$0.value.isEmpty && !$0.multiline }) { f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(f.label).font(.system(size: 11)).foregroundStyle(Tokens.faint).frame(width: 64, alignment: .leading)
                    Text(f.value).font(.system(size: 12)).lineLimit(1)
                }
            }
            ForEach(shown.fields.filter { !$0.value.isEmpty && $0.multiline }) { f in
                Text(f.value).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(compact ? 3 : 8).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Tokens.stroke).frame(width: 2) }
            }
        }
    }
}

/// A bot's report: who, when, what it did, and what it wrote.
struct BotReportCard: View {
    let module: BotsModule
    let run: BotRun
    var compact: Bool

    private var bot: Bot? { module.store.bot(run.botID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let bot {
                    OrbitView(size: compact ? 24 : 28, motion: run.state == .working ? .working : run.read ? .still : .glow,
                              tint: Appearance.companion(bot.color).body, colors: Appearance.companion(bot.color))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(compact ? "\(bot?.name ?? "Bot") · \(run.title)" : run.title)
                        .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !run.read && !run.isOpen {
                    Button(compact ? "Done" : "Mark read") { module.runner.markRead(run.id) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.secondary)
                }
            }
            if run.state == .working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(run.steps.last ?? "Starting…").font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !compact {
                        Button("Stop") { Task { await module.runner.stop(run.id) } }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.secondary)
                    }
                }
            }
            if let report = run.report {
                Text(report).font(.system(size: compact ? 12 : 12.5)).lineLimit(compact ? 4 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11.5))
                    .foregroundStyle(Tokens.attention).fixedSize(horizontal: false, vertical: true)
            }
            if !compact && !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(NSOrderedSet(array: run.steps).compactMap { $0 as? String }.enumerated()), id: \.offset) { _, step in
                        Text(step).font(.system(size: 10.5))
                            .foregroundStyle(step.hasPrefix("You approved") ? Tokens.live : step.hasPrefix("You skipped") || step.hasPrefix("Refused") || step.hasPrefix("Failed") ? Tokens.attention : Tokens.faint)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
        .contentShape(Rectangle())
        .onTapGesture { if compact { module.show(run); module.openPanelForBots() } }
    }

    private var subtitle: String {
        var parts = [run.started.formatted(.dateTime.weekday(.abbreviated).hour().minute())]
        if let c = run.costCents { parts.append(BotRunner.dollars(c)) }
        if let t = run.tokens, t > 0 { parts.append("\(t.formatted()) tokens") }
        if let w = run.webSearches, w > 0 { parts.append("\(w) web \(w == 1 ? "search" : "searches")") }
        switch run.state {
        case .working: parts.append("working")
        case .waiting: parts.append("waiting for you")
        case .failed: parts.append("didn't finish")
        case .budget: parts.append("hit its cap")
        case .done: break
        }
        return parts.joined(separator: " · ")
    }
}

/// "Let Account Manager log notes in HubSpot on its own?"
struct TrustOfferCard: View {
    let module: BotsModule
    let offer: TrustOffer

    var body: some View {
        let bot = module.store.bot(offer.botID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let bot { OrbitView(size: 28, mood: .happy, motion: .still, colors: Appearance.companion(bot.color)) }
                Text("Let \(bot?.name ?? "this bot") \(BotsModule.verb(offer.tool)) on its own?")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Text("You've approved the last \(BotRunner.trustAfter) without changing anything. It would then act right away and tell you, with Undo for 10 minutes. You can take this back in Settings → Bots.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { module.runner.answer(offer, yes: true) } label: {
                    Text("Yes, let it").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(.white)).foregroundStyle(.black).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button("Keep asking me") { module.runner.answer(offer, yes: false) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.secondary)
                    .padding(.horizontal, 8).frame(height: 28)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
    }
}

/// What a bot did on its own in the last day, with Undo for the first 10 minutes.
struct OnItsOwnList: View {
    let module: BotsModule
    let botID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let recent = module.runner.actions.filter { $0.botID == botID && context.date.timeIntervalSince($0.at) < 86400 }.suffix(4)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    CardLabel("Did on its own")
                    ForEach(Array(recent.reversed())) { action in
                        HStack(spacing: 6) {
                            Image(systemName: action.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(action.undone ? Tokens.faint : Tokens.live)
                            Text(action.title).font(.system(size: 11.5)).lineLimit(1)
                                .strikethrough(action.undone).foregroundStyle(action.undone ? Tokens.faint : .white)
                            Spacer(minLength: 0)
                            if action.canUndo(now: context.date) {
                                Button("Undo") { Task { await module.runner.undo(action.id) } }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.attention)
                            } else {
                                Text(action.undone ? "Undone" : action.at.formatted(.dateTime.hour().minute()))
                                    .font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

/// Hand-offs between bots, newest first: who handed what to whom, and how it went.
struct TeamActivity: View {
    let module: BotsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Team").font(.system(size: 15, weight: .semibold))
                Text("When a bot hands work to another, it shows up here.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }
            NotchScroll {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(module.runner.handoffs.prefix(12)) { run in row(run) }
                }
            }
        }
    }

    private func row(_ run: BotRun) -> some View {
        let from = run.fromBotID.flatMap(module.store.bot)
        let to = module.store.bot(run.botID)
        return Button { module.show(run) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let from { OrbitView(size: 22, motion: .still, colors: Appearance.companion(from.color)) }
                    Text(from?.name ?? "A bot").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.faint)
                    if let to { OrbitView(size: 22, motion: run.state == .working ? .working : .still, colors: Appearance.companion(to.color)) }
                    Text(to?.name ?? "A bot").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Circle().fill(BotDetail.color(run)).frame(width: 6, height: 6)
                    Text(run.started.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                }
                if let task = run.handoffTask {
                    Text(task).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = run.report?.split(separator: "\n").first ?? run.error.map({ Substring($0) }) {
                    Text(line).font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
