import AppKit
import SwiftUI
import OrbitKit

/// Home: your own start page, a free canvas. Edit Home (at the bottom) to drag widgets anywhere,
/// resize them from the corner, remove them or add more.
struct HomeFeed: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry
    private var look: Appearance { Appearance.shared }
    @State private var editing = false

    /// Clicking a widget opens its feature's page.
    private func open(_ tab: String) { vm.selectedTab = tab }

    var body: some View {
        // Snapshots can't draw scroll views, so preview mode shows the feed without one.
        if ModuleRegistry.isPreview { feed } else { ScrollView(.vertical, showsIndicators: false) { feed } }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 10) {
            GetStartedCard(vm: vm, registry: registry)
            if editing { editBar }
            HomeCanvas(keys: shownKeys, editing: editing, content: widget, onRemove: remove)
            if !editing {
                Button { withAnimation(Tokens.spring) { editing = true } } label: {
                    Label("Edit Home", systemImage: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(Tokens.faint)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Tokens.stroke.opacity(3)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Which widgets

    /// Every widget that's shown, in your order. Keys: built-in names, "addon:<id>".
    private var shownKeys: [String] {
        let builtIn = look.widgets.filter(isAvailable).map(\.rawValue)
        let hidden = Set(look.hiddenAddOnWidgets)
        let addOns = registry.enabled.filter { $0 is any AddOnModule && !hidden.contains($0.id) && $0.homeCard != nil }.map { "addon:" + $0.id }
        return Appearance.ordered(builtIn + addOns, by: look.homeOrder)
    }

    private func isAvailable(_ w: Appearance.Widget) -> Bool {
        switch w {
        case .agents: registry.module(AgentsModule.self).map { registry.isEnabled($0.id) } ?? false
        case .photos: registry.module(PhotosModule.self).map { registry.isEnabled($0.id) } ?? false
        case .bots: registry.module(BotsModule.self) != nil
        case .brief: registry.module(SmartAssistant.self) != nil
        default: true
        }
    }

    /// Widgets you can add back: built-ins you removed, and add-on widgets you hid.
    private var addable: [(key: String, name: String)] {
        let shown = Set(shownKeys)
        let builtIn = Appearance.Widget.allCases.filter { isAvailable($0) && !shown.contains($0.rawValue) }.map { ($0.rawValue, $0.name) }
        let addOns = registry.enabled.filter { $0 is any AddOnModule && $0.homeCard != nil && !shown.contains("addon:" + $0.id) }
            .map { ("addon:" + $0.id, $0.title) }
        return builtIn + addOns
    }

    private func widget(_ key: String) -> AnyView? {
        if key.hasPrefix("addon:") {
            let id = String(key.dropFirst(6))
            return registry.enabled.first { $0.id == id }?.homeCard
        }
        guard let w = Appearance.Widget(rawValue: key) else { return nil }
        switch w {
        case .greeting: return AnyView(GreetingWidget())
        case .brief: return registry.module(SmartAssistant.self).map { AnyView(BriefWidget(smart: $0)) }
        case .shortcuts: return AnyView(ShortcutTiles())
        case .glance: return AnyView(GlanceRow(tasks: registry.module(TasksModule.self), open: open))
        case .now: return AnyView(NowAndNext(meetings: registry.module(MeetingsModule.self), tasks: registry.module(TasksModule.self),
                                             smart: registry.module(SmartAssistant.self), open: open).homeCard())
        case .bots: return registry.module(BotsModule.self).map { AnyView(BotsHomeWidget(module: $0, open: open).homeCard()) }
        case .agents: return registry.module(AgentsModule.self).map { AnyView(AgentsWidget(agents: $0, open: open).homeCard()) }
        case .media: return AnyView(MediaRow(music: registry.module(MusicModule.self), focus: registry.module(FocusModule.self), open: open))
        case .numbers: return registry.module(TasksModule.self).map { AnyView(NumbersRow(tasks: $0, open: open)) }
        case .photos: return registry.module(PhotosModule.self).map { AnyView(PhotoCard(module: $0, compact: true).frame(height: 150)) }
        }
    }

    private func remove(_ key: String) {
        if key.hasPrefix("addon:") {
            look.hiddenAddOnWidgets.append(String(key.dropFirst(6)))
        } else {
            look.homeWidgets.removeAll { $0 == key }
        }
    }

    private func add(_ key: String) {
        if key.hasPrefix("addon:") {
            look.hiddenAddOnWidgets.removeAll { $0 == String(key.dropFirst(6)) }
        } else if !look.homeWidgets.contains(key) {
            look.homeWidgets.append(key)
        }
        // New ones get a place at the bottom and are drawn on top.
        look.homeFrames[key] = nil
        look.bringToFront(key)
    }

    // MARK: Editing

    private var editBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw").foregroundStyle(Tokens.secondary)
            Text("Drag a widget to move it, its corner to resize it.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
            Spacer()
            Menu {
                if addable.isEmpty { Text("Everything is on Home") }
                ForEach(addable, id: \.key) { item in Button(item.name) { add(item.key) } }
                Divider()
                Button("Reset layout") { look.homeOrder = []; look.homeSizes = [:]; look.homeFrames = [:] }
            } label: {
                Label("Add widget", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Tokens.surface2)).contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { withAnimation(Tokens.spring) { editing = false } } label: {
                Text("Done").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().fill(.white)).foregroundStyle(.black).contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}

/// How much of a row a Home widget takes (1/3, 1/2 or 1).
struct HomeSpan: LayoutValueKey {
    static let defaultValue: Double = 1
}

/// Packs widgets into rows by width, left to right; each row is as tall as its tallest widget.
struct HomeGrid: Layout {
    var spacing: CGFloat = 10

    /// For each widget: its row, x and width. Pure, so it's easy to test.
    static func arrange(_ spans: [Double], width: CGFloat, spacing: CGFloat) -> [(row: Int, x: CGFloat, width: CGFloat)] {
        var out: [(Int, CGFloat, CGFloat)] = []
        var row = 0, used = 0.0, x: CGFloat = 0
        for span in spans {
            let f = min(max(span, 0.05), 1)
            if used + f > 1.0001 { row += 1; used = 0; x = 0 }
            let w = f >= 0.999 ? width : (width + spacing) * f - spacing
            out.append((row, x, max(w, 0)))
            used += f
            x += w + spacing
        }
        return out
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let spans = subviews.map { $0[HomeSpan.self] }
        let places = Self.arrange(spans, width: width, spacing: spacing)
        var rowHeights: [Int: CGFloat] = [:]
        var heights: [CGFloat] = []
        for (i, p) in places.enumerated() {
            let h = subviews[i].sizeThatFits(ProposedViewSize(width: p.width, height: nil)).height
            heights.append(h)
            rowHeights[p.row] = max(rowHeights[p.row] ?? 0, h)
        }
        var rowY: [Int: CGFloat] = [:]
        var y: CGFloat = 0
        for r in 0...(places.map(\.row).max() ?? 0) {
            rowY[r] = y
            y += (rowHeights[r] ?? 0) + (rowHeights[r] == nil ? 0 : spacing)
        }
        let frames = places.enumerated().map { i, p in CGRect(x: p.x, y: rowY[p.row] ?? 0, width: p.width, height: heights[i]) }
        return (frames, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: layout(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layout(subviews, width: bounds.width).frames
        for (i, f) in frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// Your bots on Home: what waits for your OK, the newest report, and who's working.
private struct BotsHomeWidget: View {
    let module: BotsModule
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open(module.id) } label: {
                HStack(spacing: 4) {
                    Text("Bots").font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            if let ask = module.runner.approvals.first {
                ApprovalCard(module: module, approval: ask, compact: true)
            } else if let run = module.runner.unread.first {
                BotReportCard(module: module, run: run, compact: true)
            }
            let bots = module.store.bots.filter(\.enabled)
            if bots.isEmpty {
                FeedRow(title: "No bots switched on", subtitle: "Chief of Staff writes your morning briefing") {
                    OrbitView(size: 32, mood: .closed, motion: .still, colors: Appearance.companion("sunny"))
                } trailing: { EmptyView() }
                .contentShape(Rectangle())
                .onTapGesture { open(module.id) }
            }
            ForEach(bots.prefix(4)) { bot in
                let asks = module.runner.approvals(for: bot.id).count
                let working = module.runner.working.contains { $0.botID == bot.id }
                FeedRow(title: bot.name, subtitle: asks > 0 ? "Needs your OK (\(asks))" : BotDetail.status(bot, module: module), hot: asks > 0) {
                    OrbitView(size: 32, motion: asks > 0 ? .nudge : working ? .working : .still, tint: Tokens.attention,
                              colors: Appearance.companion(bot.color))
                } trailing: { EmptyView() }
                .contentShape(Rectangle())
                .onTapGesture {
                    module.selection = bot.id
                    open(module.id)
                }
            }
        }
    }
}

// MARK: - Building blocks

extension View {
    /// A glass card around a Home widget that doesn't draw its own, so it reads as one piece on the canvas.
    func homeCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassCard(22)
    }
}

/// A soft, borderless tile like Dots' widgets.
struct Tile<Content: View>: View {
    var height: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .glassCard(22)
    }
}

private struct BigNumber: View {
    let text: String
    var size: CGFloat = 34
    var body: some View {
        Text(text).font(.system(size: size, weight: .heavy).monospacedDigit()).tracking(-0.5)
    }
}

private struct Label2: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Tokens.secondary)
    }
}

/// A plain row with an icon tile, two lines of text and something on the right.
struct FeedRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    var hot = false
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hot ? Color.white.opacity(0.07) : .clear))
    }
}

private struct SmallChip: View {
    let text: String
    var color: Color = .white.opacity(0.75)
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Widgets

private struct GreetingWidget: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Appearance.shared.greeting).font(.system(size: 15, weight: .bold))
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 13)).foregroundStyle(Tokens.secondary)
        }
        .padding(.horizontal, 4)
    }
}

/// App and link shortcuts as square tiles; "+" adds an app.
private struct ShortcutTiles: View {
    private var look: Appearance { Appearance.shared }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(look.shortcuts, id: \.self) { item in
                Button { open(item) } label: { tile(item) }
                    .buttonStyle(.plain)
                    .help(name(item))
                    .contextMenu { Button("Remove shortcut") { look.shortcuts.removeAll { $0 == item } } }
            }
            Button(action: addApp) {
                Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(Tokens.secondary)
                    .frame(width: 54, height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Add an app")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func tile(_ item: String) -> some View {
        Group {
            if item.hasPrefix("/") {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item)).renderingMode(.original).resizable()
                    .frame(width: 34, height: 34)
            } else {
                Text(String(name(item).prefix(1)).uppercased()).font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(item.contains("hubspot") ? Color(red: 1, green: 0.48, blue: 0.35) : .white)
            }
        }
        .frame(width: 54, height: 54)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func name(_ item: String) -> String {
        if item.hasPrefix("/") { return URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent }
        let host = URL(string: item)?.host ?? item
        return host.replacingOccurrences(of: "app.", with: "").replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: ".").first?.capitalized ?? item
    }

    private func open(_ item: String) {
        if item.hasPrefix("/") {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item), configuration: .init())
        } else if let url = URL(string: item) {
            NSWorkspace.shared.open(url)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url, !look.shortcuts.contains(url.path) {
            look.shortcuts.append(url.path)
        }
    }
}

/// Time · date · countdown.
private struct GlanceRow: View {
    let tasks: TasksModule?
    let open: (String) -> Void

    var body: some View {
        // Quarter · quarter · half, like the mockup.
        GeometryReader { geo in
            let q = (geo.size.width - 20) / 4
            HStack(spacing: 10) {
                timeTile.frame(width: q).contentShape(Rectangle()).onTapGesture { open("meetings") }
                dateTile.frame(width: q).contentShape(Rectangle()).onTapGesture { open("meetings") }
                Tile(height: 108) { countdown }.frame(width: q * 2).contentShape(Rectangle()).onTapGesture { open("tasks") }
            }
        }
        .frame(height: 108)
    }

    private var timeTile: some View {
            TimelineView(.everyMinute) { ctx in
                Tile(height: 108) {
                    VStack(alignment: .leading) {
                        Label2(text: ctx.date.formatted(.dateTime.weekday(.wide)))
                        Spacer(minLength: 0)
                        BigNumber(text: ctx.date.formatted(.dateTime.hour().minute()), size: 28)
                    }
                }
            }
    }

    private var dateTile: some View {
        Tile(height: 108) {
            VStack(alignment: .leading) {
                Label2(text: Date.now.formatted(.dateTime.weekday(.abbreviated)))
                Spacer(minLength: 0)
                BigNumber(text: Date.now.formatted(.dateTime.day()))
            }
        }
    }

    @ViewBuilder private var countdown: some View {
        let cal = Calendar.current
        let look = Appearance.shared
        let custom = look.countdownTitle.trimmingCharacters(in: .whitespaces)
        let nextTask = tasks?.items.filter { !$0.done && ($0.due ?? .distantPast) > .now }.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let target: (String, Date, String)? = !custom.isEmpty && look.countdownDate > .now
            ? (custom, look.countdownDate, "Countdown")
            : nextTask.map { t in (t.title, t.due!, [t.project, t.source == "hubspot" ? "HubSpot" : "Task"].compactMap { $0 }.joined(separator: " · ")) }
        if let (title, date, source) = target {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
            VStack(alignment: .leading, spacing: 4) {
                BigNumber(text: days == 0 ? "Today" : "\(days)", size: days == 0 ? 28 : 34)
                Spacer(minLength: 0)
                Text(days == 0 ? title : "day\(days == 1 ? "" : "s") to \(title)").font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text("\(source) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading) {
                Label2(text: "Week")
                Spacer(minLength: 0)
                BigNumber(text: "\(cal.component(.weekOfYear, from: .now))")
            }
        }
    }
}

/// Next meeting and today's tasks as plain rows; whatever needs you is highlighted with its action.
private struct NowAndNext: View {
    let meetings: MeetingsModule?
    let tasks: TasksModule?
    let smart: SmartAssistant?
    let open: (String) -> Void

    var body: some View {
        let meeting = meetings?.next.flatMap { Calendar.current.isDateInToday($0.start) || $0.isNow ? $0 : nil }
        let taskRows = Array((tasks.map { $0.today.filter { !$0.done } + $0.someday.filter { !$0.done } } ?? []).prefix(3))
        VStack(spacing: 2) {
            if meeting == nil && taskRows.isEmpty {
                FeedRow(title: "Nothing coming up", subtitle: "No more meetings or tasks today") {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Tokens.live)
                } trailing: { EmptyView() }
            }
            if let m = meeting, let meetings {
                let joinable = meetings.joinable?.id == m.id
                FeedRow(title: m.title.trimmingCharacters(in: .whitespaces),
                        subtitle: [m.timeRange, m.link?.provider.rawValue].compactMap { $0 }.joined(separator: " · "),
                        hot: joinable) {
                    Image(systemName: m.link == nil ? "calendar" : "video.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(m.link?.provider.tint ?? Tokens.secondary)
                } trailing: {
                    HStack(spacing: 6) {
                        // Prep: HubSpot context on the attendees, summarised by Claude.
                        if let smart, smart.isConfigured, !m.attendeeEmails.isEmpty {
                            Button { smart.prepare(m) } label: {
                                Label("Prep", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help("Who's attending, deals, last notes and talking points")
                        }
                        if joinable, let link = m.link {
                            PillButton(title: "Join", fill: link.provider.tint) { meetings.join(m) }
                        } else {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                SmallChip(text: m.isNow ? "Now" : "in " + Meeting.countdown(to: m.start))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open("meetings") }
            }
            if let tasks {
                ForEach(taskRows) { t in
                    Button { tasks.show(t) } label: {
                        FeedRow(title: t.title, subtitle: [t.project, t.source == "hubspot" ? "HubSpot" : "On this Mac"].compactMap { $0 }.joined(separator: " · "),
                                hot: t.isOverdue) {
                            Image(systemName: t.source == "hubspot" ? "h.square.fill" : "checklist").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(t.source == "hubspot" ? Color(red: 1, green: 0.48, blue: 0.35) : Tokens.secondary)
                        } trailing: {
                            if t.isOverdue {
                                HStack(spacing: 6) {
                                    SmallChip(text: "Overdue", color: Tokens.error)
                                    PillButton(title: "Done") { tasks.toggle(t) }
                                }
                            } else if let due = t.due {
                                SmallChip(text: Calendar.current.isDateInToday(due) && t.dueHasTime
                                          ? due.formatted(.dateTime.hour().minute())
                                          : due.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                                          color: t.isDueToday ? Tokens.attention : .white.opacity(0.75))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Agent sessions, or today's usage.
private struct AgentsWidget: View {
    let agents: AgentsModule
    let open: (String) -> Void
    @State private var showUsage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { open("agents") } label: {
                    HStack(spacing: 4) {
                        Text("Agents").font(.system(size: 14, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 0) {
                    seg("Sessions", !showUsage) { showUsage = false }
                    seg("Usage", showUsage) { showUsage = true }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .padding(.horizontal, 4)

            if showUsage {
                let u = agents.usage
                FeedRow(title: "\(u.sessions.count) session\(u.sessions.count == 1 ? "" : "s") today",
                        subtitle: "Claude Code · \(Self.duration(u.workingNow)) working · \(u.toolRuns) tool runs") {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 13, weight: .bold))
                } trailing: { SmallChip(text: "Today") }
            } else if agents.sessions.isEmpty && agents.asks.isEmpty && agents.items.isEmpty {
                FeedRow(title: "No agent sessions right now", subtitle: "Claude Code shows here while it works") {
                    OrbitView(size: 36, motion: .sleep)
                } trailing: { EmptyView() }
            } else {
                ForEach(agents.asks) { ask in
                    FeedRow(title: ask.request.title, subtitle: ask.request.subtitle ?? "From your terminal", hot: true) {
                        Image(systemName: "questionmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Tokens.attention)
                    } trailing: {
                        HStack(spacing: 6) {
                            ForEach(ask.request.actions, id: \.self) { a in
                                PillButton(title: a, fill: a == ask.request.actions.last ? Tokens.attention : Tokens.surface2) {
                                    agents.answer(ask.id, with: a)
                                }
                            }
                        }
                    }
                }
                ForEach(agents.sessions.prefix(3)) { s in
                    FeedRow(title: s.project, subtitle: "\(s.agent) · \(s.detail)", hot: s.state == .needsInput) {
                        OrbitView.agent(project: s.project, state: s.state, size: 36)
                    } trailing: {
                        switch s.state {
                        case .working: WorkingBar()
                        case .needsInput: SmallChip(text: "Needs you", color: Tokens.attention)
                        case .done: SmallChip(text: "Finished")
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open("agents") }
                ForEach(agents.items.prefix(2)) { item in
                    FeedRow(title: item.title, subtitle: item.subtitle ?? "From your terminal") {
                        Image(systemName: "terminal").font(.system(size: 14, weight: .semibold))
                    } trailing: {
                        if let p = item.progress {
                            ProgressBar(value: p, tint: item.status == .error ? Tokens.error : Tokens.live).frame(width: 64)
                        } else {
                            SmallChip(text: item.status.rawValue.capitalized)
                        }
                    }
                }
            }
        }
    }

    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : Tokens.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.white.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// A small bar that slides back and forth while an agent works.
private struct WorkingBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let x = (sin(t * 2.2) + 1) / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(.white).frame(width: 26).offset(x: x * 38)
            }
            .frame(width: 64, height: 4)
        }
    }
}

/// Music and Focus, side by side.
private struct MediaRow: View {
    let music: MusicModule?
    let focus: FocusModule?
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let music {
                Tile(height: 92) {
                    HStack(spacing: 12) {
                        RecordOrCover(image: music.artwork, spinning: music.track?.isPlaying ?? false, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Label2(text: music.track?.player.rawValue ?? "Music")
                            Text(music.track?.title ?? "Nothing playing").font(.system(size: 14, weight: .bold)).lineLimit(1)
                            Text(music.track?.artist ?? "Spotify or Music").font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let t = music.track {
                            IconButton(symbol: t.isPlaying ? "pause.fill" : "play.fill") { music.send(.playPause) }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open("music") }
            }
            if let focus {
                Tile(height: 92) {
                    HStack(spacing: 12) {
                        MiniRing(fraction: focus.stage == .idle ? 1 : focus.fraction, running: focus.isRunning, rest: focus.phase == .rest)
                        VStack(alignment: .leading, spacing: 2) {
                            Label2(text: focus.headline)
                            BigNumber(text: FocusModule.clock(focus.remaining), size: 22)
                            Text(focus.stage == .idle
                                 ? (focus.timers.isEmpty ? "\(focus.rounds) × \(focus.cycleFocusMinutes) min" : "\(focus.timers.count) timer\(focus.timers.count == 1 ? "" : "s") running")
                                 : focus.detail)
                                .font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        PillButton(title: { switch focus.stage {
                            case .idle: "Start"
                            case .running: "Pause"
                            case .paused: "Resume"
                            case .breakReady: "Break"
                            case .focusReady: "Focus"
                        } }()) { focus.toggle() }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open("focus") }
            }
        }
    }
}

/// Big numbers about your tasks.
private struct NumbersRow: View {
    let tasks: TasksModule
    let open: (String) -> Void

    var body: some View {
        let openItems = tasks.items.filter { !$0.done }
        let hubspotOpen = openItems.filter { $0.source == "hubspot" }
        let shown = tasks.hubSpotConnected ? hubspotOpen : openItems
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
        let dueSoon = shown.filter { ($0.due ?? .distantFuture) < weekEnd }.count
        let doneToday = tasks.items.filter { $0.done && ($0.completedAt.map(Calendar.current.isDateInToday) ?? false) }.count
        HStack(spacing: 10) {
            Tile(height: 104) {
                VStack(alignment: .leading, spacing: 6) {
                    Label2(text: tasks.hubSpotConnected ? "Open tasks · HubSpot" : "Open tasks")
                    BigNumber(text: "\(shown.count)")
                    Text("\(dueSoon) due this week").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
            }
            Tile(height: 104) {
                VStack(alignment: .leading, spacing: 6) {
                    Label2(text: "Done today")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        BigNumber(text: "\(doneToday)")
                        if doneToday > 0 { Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .heavy)).foregroundStyle(Tokens.live) }
                    }
                    Text("Ticked off in Orbit").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open("tasks") }
    }
}

/// The dotted texture behind the open panel (Dots' signature look).
struct DottedBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 13
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.white.opacity(0.075)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// Just the 12 dots of the focus ring (the time is shown next to it).
private struct MiniRing: View {
    let fraction: Double
    let running: Bool
    let rest: Bool

    var body: some View {
        let lit = Int((fraction * 12).rounded(.up))
        let color = rest ? Tokens.attention : running ? Tokens.live : .white
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                let a = Double(i) / 12 * 2 * .pi - .pi / 2
                Circle().fill(i < lit ? color : Tokens.surface2).frame(width: 6, height: 6)
                    .offset(x: cos(a) * 25, y: sin(a) * 25)
            }
        }
        .frame(width: 58, height: 58)
    }
}
