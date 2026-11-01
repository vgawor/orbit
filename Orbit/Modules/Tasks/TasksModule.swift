import AppKit
import SwiftUI

/// To-dos from every task provider, with quick add ("Call Anna tomorrow 10:00").
@MainActor
@Observable
final class TasksModule: NotchModule {
    let id = "tasks"
    let title = "Tasks"
    let symbol = "checkmark.circle"

    private(set) var items: [TaskItem] = []
    private(set) var lastError: String?
    private(set) var isLoading = false
    /// Where new tasks go: "local" or "hubspot".
    var addTarget = UserDefaults.standard.string(forKey: "tasks.addTarget") ?? "local" {
        didSet { UserDefaults.standard.set(addTarget, forKey: "tasks.addTarget") }
    }
    /// The task whose details are open in the Tasks tab.
    var selectedID: String?
    var selected: TaskItem? { items.first { $0.id == selectedID } }
    private let providers: [any TaskProvider]
    private let openPanel: @MainActor (String) -> Void
    private var timer: Timer?

    init(providers: [any TaskProvider] = [LocalTaskProvider(), HubSpotTaskProvider()],
         openPanel: @escaping @MainActor (String) -> Void) {
        self.providers = providers
        self.openPanel = openPanel
    }

    var hubSpotConnected: Bool { HubSpotTaskProvider.isConfigured }

    func start() {
        Task { await reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    func stop() { timer?.invalidate() }

    func reload() async {
        isLoading = true
        var all: [TaskItem] = []
        var errors: [String] = []
        for p in providers {
            do { all += try await p.fetch() } catch { errors.append("\(p.displayName): \(error.localizedDescription)") }
        }
        // If a source fails, keep showing what it had before instead of emptying the list.
        let failed = Set(providers.map(\.sourceID)).subtracting(all.map(\.source))
        if !errors.isEmpty { all += items.filter { failed.contains($0.source) } }
        items = all
        lastError = errors.first
        isLoading = false
    }

    private func provider(for item: TaskItem) -> (any TaskProvider)? {
        providers.first { $0.sourceID == item.source }
    }

    // MARK: Actions

    func add(_ text: String) {
        let parsed = TaskParser.parse(text)
        let target = hubSpotConnected ? addTarget : "local"
        guard !parsed.title.isEmpty, let provider = providers.first(where: { $0.sourceID == target }) else { return }
        let draft = TaskItem(title: parsed.title, due: parsed.due, dueHasTime: parsed.hasTime, source: target)
        items.append(draft)
        Task {
            do {
                let saved = try await provider.add(draft)
                if let i = items.firstIndex(where: { $0.id == draft.id }) { items[i] = saved }
            } catch {
                items.removeAll { $0.id == draft.id }
                lastError = "\(provider.displayName): \(error.localizedDescription)"
            }
        }
    }

    func toggle(_ item: TaskItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].done.toggle()
        items[i].completedAt = items[i].done ? .now : nil
        let updated = items[i]
        Task {
            do { try await provider(for: updated)?.update(updated) } catch {
                // Put it back if the source didn't accept the change.
                if let j = items.firstIndex(where: { $0.id == updated.id }) { items[j].done.toggle() }
                lastError = error.localizedDescription
            }
        }
    }

    /// The HubSpot task form is open (with this text as a starting point).
    var composing: String?
    /// The form for a task on this Mac is open (with this text as a starting point).
    var composingLocal: String?
    /// Which tasks the list shows (Tasks tab filter).
    enum Filter: String, CaseIterable { case all = "All", today = "Today", upcoming = "Upcoming", hubspot = "HubSpot" }
    var filter: Filter = .all
    var hubspot: HubSpotTaskProvider? { providers.lazy.compactMap { $0 as? HubSpotTaskProvider }.first }

    /// Creates a HubSpot task from the form. Returns an error message, or nil when it worked.
    func createHubSpot(_ draft: HubSpotTaskProvider.Draft) async -> String? {
        guard let hubspot else { return "HubSpot isn't connected." }
        do {
            let task = try await hubspot.create(draft)
            items.append(task)
            composing = nil
            selectedID = task.id
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Adds a task on this Mac with an exact due date (used by Smart Ask).
    func addLocal(title: String, due: Date?, hasTime: Bool) {
        guard let local = providers.first(where: { $0.sourceID == "local" }) else { return }
        let draft = TaskItem(title: title, due: due, dueHasTime: hasTime)
        items.append(draft)
        Task {
            if let saved = try? await local.add(draft), let i = items.firstIndex(where: { $0.id == draft.id }) { items[i] = saved }
        }
    }

    /// Adds a task from the "New task" form (due date, priority, link and notes already filled in).
    func addLocal(_ draft: TaskItem) {
        guard let local = providers.first(where: { $0.sourceID == "local" }) else { return }
        var draft = draft
        draft.source = "local"
        items.append(draft)
        Task {
            do {
                let saved = try await local.add(draft)
                if let i = items.firstIndex(where: { $0.id == draft.id }) { items[i] = saved }
            } catch {
                items.removeAll { $0.id == draft.id }
                lastError = error.localizedDescription
            }
        }
    }

    /// Saves changes to a task (title, due date, status) to wherever it lives.
    func apply(_ updated: TaskItem) async throws {
        guard let i = items.firstIndex(where: { $0.id == updated.id }) else { return }
        let before = items[i]
        items[i] = updated
        do { try await provider(for: updated)?.update(updated) } catch {
            if let j = items.firstIndex(where: { $0.id == before.id }) { items[j] = before }
            throw error
        }
    }

    /// Opens the Tasks tab on this task's details.
    func show(_ item: TaskItem) {
        selectedID = item.id
        openPanel(id)
    }

    /// Changes a HubSpot task's status (Not started, In progress, Waiting, Done).
    func setStatus(_ item: TaskItem, _ status: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let before = items[i]
        items[i].status = status
        items[i].done = status == "COMPLETED"
        items[i].completedAt = items[i].done ? .now : nil
        let updated = items[i]
        Task {
            do { try await provider(for: updated)?.update(updated) } catch {
                if let j = items.firstIndex(where: { $0.id == before.id }) { items[j] = before }
                lastError = error.localizedDescription
            }
        }
    }

    func delete(_ item: TaskItem) {
        guard item.source == "local" else { return }
        items.removeAll { $0.id == item.id }
        Task { try? await provider(for: item)?.delete(id: item.id) }
    }

    // MARK: Groups

    private func byDue(_ a: TaskItem, _ b: TaskItem) -> Bool {
        (a.due ?? .distantFuture, a.created) < (b.due ?? .distantFuture, b.created)
    }

    /// Open tasks, plus tasks ticked off today: those stay in place (ticked) until the day ends, then leave Orbit.
    private var visible: [TaskItem] {
        items.filter { !$0.done || ($0.completedAt.map(Calendar.current.isDateInToday) ?? false) }
    }
    private var startOfTomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
    }
    /// Ticked tasks sink to the bottom of their group.
    private func ordered(_ list: [TaskItem]) -> [TaskItem] {
        list.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, $0.created) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, $1.created) }
    }

    /// Overdue + due today (and what you ticked off today from them).
    var today: [TaskItem] { ordered(visible.filter { ($0.due.map { $0 < startOfTomorrow } ?? false) }) }
    var upcoming: [TaskItem] { ordered(visible.filter { ($0.due.map { $0 >= startOfTomorrow } ?? false) }) }
    var someday: [TaskItem] { ordered(visible.filter { $0.due == nil }) }
    /// How many of today's tasks are still open.
    var todayLeft: Int { today.filter { !$0.done }.count }

    // MARK: Views

    /// Overdue tasks you snoozed don't count as overdue until the snooze ends.
    var overdueSnoozed: Bool { overdueAttentionID.map { NudgeSnoozes.shared.isSnoozed($0) } ?? false }

    var peekChip: PeekChip? {
        let open = items.filter { !$0.done }
        let overdue = overdueSnoozed ? 0 : open.filter(\.isOverdue).count
        if overdue > 0 {
            return PeekChip(symbol: "exclamationmark.circle.fill", text: "\(overdue) overdue", tint: Tokens.error, priority: 3)
        }
        let left = todayLeft
        guard left > 0 else { return nil }
        return PeekChip(symbol: "checklist", text: "\(left) due today", tint: Tokens.attention, priority: 2)
    }

    var attention: Attention? {
        let open = items.filter { !$0.done }
        if let soon = open.filter({ $0.dueHasTime && !$0.isOverdue }).compactMap({ t in t.due.map { (t, $0) } })
            .first(where: { $0.1.timeIntervalSinceNow < 900 }) {
            return Attention(id: "task-soon-\(soon.0.id)", symbol: "checklist", tint: Tokens.attention,
                             label: soon.1.formatted(.dateTime.hour().minute()), priority: 2,
                             headline: "Task due \(soon.1.formatted(.dateTime.hour().minute()))")
        }
        let overdue = open.filter(\.isOverdue)
        guard let id = overdueAttentionID else { return nil }
        return Attention(id: id, symbol: "exclamationmark", tint: Tokens.error,
                         label: "\(overdue.count) overdue", priority: 1, headline: "\(overdue.count) overdue")
    }

    /// Id of the "overdue" nudge. It changes when the list of overdue tasks changes, so a newly
    /// overdue task nudges again (and ends an "until it changes" snooze). Stable across restarts.
    var overdueAttentionID: String? {
        let overdue = items.filter { !$0.done && $0.isOverdue }
        guard !overdue.isEmpty else { return nil }
        return "tasks-overdue-" + overdue.map(\.id).sorted().joined(separator: ",")
    }

    var homeCard: AnyView? { AnyView(TasksHomeCard(module: self) { self.openPanel(self.id) }) }
    var panel: AnyView { AnyView(TasksPanel(module: self)) }
}

// MARK: - Views

struct TaskRow: View {
    let item: TaskItem
    let module: TasksModule
    var showDelete = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // The check circle only ticks. A bigger hit area so it's easy to hit.
            ZStack {
                Circle().stroke(item.done ? Tokens.live : Tokens.faint, lineWidth: 1.5)
                if item.done { Circle().fill(Tokens.live); Circle().fill(.black).frame(width: 5) }
            }
            .frame(width: 16, height: 16)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                withAnimation(.easeOut(duration: 0.2)) { module.toggle(item) }
            })
            .help(item.done ? "Mark as not done" : "Mark as done")
            // The rest of the row opens the details: title, then when and where it's from.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? Tokens.faint : .white)
                        .lineLimit(1)
                    if !item.done, dueLabel != nil || item.source != "local" || item.link != nil {
                        HStack(spacing: 6) {
                            if let label = dueLabel {
                                Text(label).font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(item.isOverdue && !module.overdueSnoozed ? Tokens.attention : item.isDueToday ? .white.opacity(0.8) : Tokens.secondary)
                            }
                            if item.source == "hubspot" {
                                Text(item.project ?? "HubSpot").font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Self.hubSpotTint.opacity(0.2)))
                                    .foregroundStyle(Self.hubSpotTint)
                                    .frame(maxWidth: 140, alignment: .leading)
                            } else if item.source != "local" {
                                Text(item.source).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Tokens.secondary)
                            }
                            if item.link != nil && item.source == "local" {
                                Image(systemName: "link").font(.system(size: 9.5)).foregroundStyle(Tokens.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                if let p = item.priority, !item.done, p != "NONE" {
                    Circle().fill(Self.priorityColor(p)).frame(width: 7, height: 7)
                        .help("\(p.capitalized) priority")
                }
                if showDelete && hovering && item.source == "local" {
                    Button { module.delete(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { module.show(item) }
            .help("Click for details")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Color.white.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            if let link = item.link {
                Button("Open in HubSpot") { NSWorkspace.shared.open(link) }
            }
            Button(item.done ? "Mark as not done" : "Mark as done") { module.toggle(item) }
            if item.source == "local" {
                Button("Delete", role: .destructive) { module.delete(item) }
            }
        }
    }

    static let hubSpotTint = Color(red: 1, green: 0.64, blue: 0.55)

    /// High red, medium amber, low blue.
    static func priorityColor(_ p: String) -> Color {
        switch p.uppercased() {
        case "HIGH": Tokens.error
        case "MEDIUM": Tokens.attention
        case "LOW": Tokens.zoom
        default: Tokens.faint
        }
    }

    private var dueLabel: String? {
        guard let due = item.due, !item.done else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(due) { return item.dueHasTime ? due.formatted(.dateTime.hour().minute()) : "Today" }
        if cal.isDateInTomorrow(due) { return "Tomorrow" }
        if cal.isDateInYesterday(due) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: due)).day ?? 0
        return (0..<7).contains(days) ? due.formatted(.dateTime.weekday(.abbreviated)) : due.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct TasksHomeCard: View {
    let module: TasksModule
    let openAll: () -> Void

    var body: some View {
        let list = Array((module.today + module.someday).prefix(4))
        NotchCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CardLabel("Today")
                    Spacer()
                    Text("\(module.todayLeft) left").font(.system(size: 10, weight: .medium)).foregroundStyle(Tokens.faint)
                }
                if list.isEmpty {
                    Spacer(minLength: 0)
                    Text("All clear").font(.system(size: 13, weight: .medium))
                    Button("Add a task", action: openAll).buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                } else {
                    ForEach(list) { TaskRow(item: $0, module: module, showDelete: false) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct TasksPanel: View {
    let module: TasksModule
    @State private var text = ""
    @FocusState private var focused: Bool
    @Namespace private var filterSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let start = module.composing, let hubspot = module.hubspot {
                NotchCard { HubSpotTaskForm(module: module, provider: hubspot, initialText: start) }
            } else if let task = module.selected {
                NotchCard { TaskDetail(item: task, module: module) }
            } else {
                toolbar
                HStack(alignment: .top, spacing: 12) {
                    listCard
                    // The New task form slides in beside the list (design: "Tasks + new task").
                    if let start = module.composingLocal {
                        LocalTaskForm(module: module, initialText: start)
                            .id(start)
                            .padding(14)
                            .frame(width: 330)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), selected: true)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Tokens.spring, value: module.composingLocal != nil)
            }
        }
        .onAppear {
            focused = true
            Task { await module.reload() }
        }
    }

    // MARK: Toolbar: filter on the left, quick add on the right

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(filters, id: \.self) { f in
                    Button { module.filter = f } label: {
                        Text(f.rawValue).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).frame(height: 26)
                            .foregroundStyle(module.filter == f ? .white : Tokens.secondary)
                            .background {
                                if module.filter == f {
                                    Capsule().fill(Color.white.opacity(0.17))
                                        .matchedGeometryEffect(id: "taskFilter", in: filterSpace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassSurface(Capsule())
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: module.filter)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if module.hubSpotConnected {
                    Picker("", selection: Binding(get: { module.addTarget }, set: { module.addTarget = $0 })) {
                        Text("Mac").tag("local")
                        Text("HubSpot").tag("hubspot")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                    .help("Where new tasks are saved")
                }
                TextField("Add a task — “Call Anna tomorrow 10”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12).frame(height: 32)
                    .frame(maxWidth: 260)
                    .glassSurface(Capsule())
                    .focused($focused)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white)).foregroundStyle(.black)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("New task")
            }
        }
    }

    private var filters: [TasksModule.Filter] {
        module.hubSpotConnected ? TasksModule.Filter.allCases : [.all, .today, .upcoming]
    }

    // MARK: List

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = module.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(Tokens.error).lineLimit(2).padding(.horizontal, 6)
            }
            NotchScroll {
                VStack(alignment: .leading, spacing: 1) {
                    let groups = self.groups
                    if groups.allSatisfy({ $0.items.isEmpty }) {
                        VStack(spacing: 8) {
                            OrbitView(size: 64, mood: .happy, motion: .idle)
                            Text(module.items.isEmpty ? "No tasks yet" : "All clear here").font(.system(size: 13, weight: .semibold))
                            Text("Type one above, like “Send offer Friday 14:00”.")
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    ForEach(groups, id: \.title) { g in
                        if !g.items.isEmpty {
                            HStack(spacing: 6) {
                                Text(g.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(g.title == "Overdue" ? Tokens.attention : Tokens.secondary)
                                Spacer()
                                if g.title == "Overdue" || g.title == "Snoozed", let id = module.overdueAttentionID {
                                    SnoozeMenuButton(attentionID: id)
                                }
                            }
                            .padding(.top, 10).padding(.bottom, 2).padding(.leading, 8).padding(.trailing, 4)
                            ForEach(g.items) { TaskRow(item: $0, module: module) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
    }

    private struct Group { let title: String; let items: [TaskItem] }

    private var groups: [Group] {
        let keep: (TaskItem) -> Bool = module.filter == .hubspot ? { $0.source == "hubspot" } : { _ in true }
        let today = module.today.filter(keep)
        let overdue = today.filter { $0.isOverdue && !$0.done }
        let rest = today.filter { !($0.isOverdue && !$0.done) }
        let upcoming = module.upcoming.filter(keep), anytime = module.someday.filter(keep)
        // Snoozed overdue tasks wait at the bottom, without the overdue colour.
        let snoozed = module.overdueSnoozed
        let late = Group(title: snoozed ? "Snoozed" : "Overdue", items: overdue)
        switch module.filter {
        case .today: return snoozed ? [Group(title: "Today", items: rest), late] : [late, Group(title: "Today", items: rest)]
        case .upcoming: return [Group(title: "Upcoming", items: upcoming)]
        case .all, .hubspot:
            let main = [Group(title: "Today", items: rest), Group(title: "Upcoming", items: upcoming), Group(title: "Anytime", items: anytime)]
            return snoozed ? main + [late] : [late] + main
        }
    }

    private func add() {
        if module.hubSpotConnected && module.addTarget == "hubspot" {
            module.composing = text
        } else {
            module.composingLocal = text
        }
        text = ""
    }
}

// MARK: - Task details

/// Everything about one task: dates, status, priority, notes, and a link to open it in HubSpot.
struct TaskDetail: View {
    let item: TaskItem
    let module: TasksModule

    static let statuses: [(String, String)] = [
        ("NOT_STARTED", "Not started"), ("IN_PROGRESS", "In progress"), ("WAITING", "Waiting"),
        ("DEFERRED", "Deferred"), ("COMPLETED", "Done"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Button { module.selectedID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).background(Circle().fill(Tokens.surface2))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text([item.project, item.source == "hubspot" ? "HubSpot" : "On this Mac"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
                Spacer()
                if let link = item.link {
                    if item.source == "hubspot" {
                        PillButton(title: "Open in HubSpot", fill: Color(red: 1, green: 0.48, blue: 0.35)) {
                            NSWorkspace.shared.open(link)
                        }
                    } else {
                        PillButton(title: "Open link") { NSWorkspace.shared.open(link) }
                            .help(link.absoluteString)
                    }
                }
            }

            // Dates: the important part
            HStack(spacing: 8) {
                dateTile("Start", item.start, hasTime: false)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Tokens.faint)
                dateTile("Due", item.due, hasTime: item.dueHasTime, highlight: true)
                VStack(alignment: .leading, spacing: 2) {
                    CardLabel("Time left")
                    Text(timeLeft).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isOverdue ? Tokens.error : item.isDueToday ? Tokens.attention : .white)
                    if let span = span { Text(span).font(.system(size: 10.5)).foregroundStyle(Tokens.faint) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Status, priority, type
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    CardLabel("Status")
                    if item.source == "hubspot" {
                        Menu {
                            ForEach(Self.statuses, id: \.0) { key, label in
                                Button(label) { module.setStatus(item, key) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(statusColor).frame(width: 7, height: 7)
                                Text(statusLabel).font(.system(size: 12.5, weight: .medium))
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.faint)
                            }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    } else {
                        Button(item.done ? "Done" : "Not done") { module.toggle(item) }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium))
                    }
                }
                field("Priority") {
                    HStack(spacing: 5) {
                        Circle().fill(priorityColor).frame(width: 7, height: 7)
                        Text(priorityLabel)
                    }
                }
                if let type = item.type {
                    field("Type") { Text(type == "TODO" ? "To-do" : type.capitalized) }
                }
                field("Assigned to") { Text("You") }
                Spacer()
            }

            // Notes
            if let notes = item.notes {
                VStack(alignment: .leading, spacing: 3) {
                    CardLabel("Notes")
                    ScrollView {
                        Text(notes).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private func dateTile(_ label: String, _ date: Date?, hasTime: Bool, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CardLabel(label)
            Text(date.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "—")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(highlight && item.isOverdue ? Tokens.error : .white)
            Text(date.map { hasTime ? $0.formatted(.dateTime.hour().minute()) : $0.formatted(.dateTime.year()) } ?? "Not set")
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Tokens.faint)
        }
        .padding(10)
        .frame(width: 130, alignment: .leading)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CardLabel(label)
            value().font(.system(size: 12.5, weight: .medium))
        }
    }

    private var timeLeft: String {
        guard let due = item.due else { return "No due date" }
        if item.done { return "Done" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<(-1): return "\(-days) days overdue"
        case -1: return "1 day overdue"
        case 0: return item.dueHasTime && due < .now ? "Overdue" : "Due today"
        case 1: return "Tomorrow"
        default: return "\(days) days left"
        }
    }

    /// How long the task spans, from start to due.
    private var span: String? {
        guard let start = item.start, let due = item.due else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: due)).day ?? 0
        return days > 0 ? "\(days)-day task" : nil
    }

    private var statusLabel: String {
        Self.statuses.first { $0.0 == (item.done ? "COMPLETED" : item.status ?? "NOT_STARTED") }?.1 ?? "Not started"
    }

    private var statusColor: Color {
        switch item.done ? "COMPLETED" : item.status ?? "NOT_STARTED" {
        case "COMPLETED": Tokens.live
        case "IN_PROGRESS": Tokens.zoom
        case "WAITING", "DEFERRED": Tokens.attention
        default: Tokens.faint
        }
    }

    private var priorityLabel: String {
        switch item.priority { case "HIGH": "High"; case "MEDIUM": "Medium"; case "LOW": "Low"; default: "None" }
    }

    private var priorityColor: Color {
        switch item.priority { case "HIGH": Tokens.error; case "MEDIUM": Tokens.attention; case "LOW": Tokens.zoom; default: Tokens.surface2 }
    }
}
