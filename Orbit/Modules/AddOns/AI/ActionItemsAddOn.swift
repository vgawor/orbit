import SwiftUI

/// Meeting notes or a transcript in, a checklist of action items out, ready for Tasks.
@MainActor
@Observable
final class ActionItemsAddOn: AddOnModule {
    let id = "addon.actionitems"
    let title = "Action items"
    let symbol = "checklist.checked"
    let addOn = AddOnInfo(category: .ai, tier: .pro, summary: "Pull the to-dos out of meeting notes and add them to Tasks.")

    var input = ""
    private(set) var items: [AILogic.ActionItem] = []
    /// Items you've ticked (all of them after a new result).
    var checked: Set<UUID> = []
    /// Items already added to Tasks.
    private(set) var added: Set<UUID> = []
    /// True when the last answer couldn't be read as JSON.
    private(set) var unreadable = false
    let request = AIRequest()
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            input = "Sync with Northwind. Sam sends the offer by Friday. Anna checks the budget with finance. Book a follow-up next week."
            let cal = Calendar.current
            let friday = cal.nextDate(after: .now, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime) ?? .now
            show([
                .init(title: "Send the offer to Northwind", owner: "Sam", due: AILogic.dayString(friday)),
                .init(title: "Check the budget with finance", owner: "Anna", due: nil),
                .init(title: "Book a follow-up meeting", owner: nil, due: nil),
            ])
            request.preview("[]")
            added = [items[2].id]
        }
    }

    /// Goes up by one each time items are added to Tasks (one click, one cheer), so Orbit can celebrate.
    private(set) var celebrations = 0

    func show(_ list: [AILogic.ActionItem]) {
        items = list
        checked = Set(list.map(\.id))
        added = []
    }

    func find() {
        let notes = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }
        items = []
        unreadable = false
        request.run(system: AILogic.actionItemsSystem(today: .now), message: AILogic.actionItemsMessage(notes)) { [weak self] raw in
            guard let parsed = AILogic.parseActionItems(raw) else {
                self?.items = []
                self?.unreadable = true
                return raw
            }
            self?.show(parsed)
            return raw
        }
    }


    func toggle(_ id: UUID) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func addToTasks(_ item: AILogic.ActionItem) {
        if add(item) { celebrations += 1 }
    }

    /// Adds one item; false when it was already in Tasks.
    private func add(_ item: AILogic.ActionItem) -> Bool {
        guard !added.contains(item.id) else { return false }
        let title = item.owner.map { "\(item.title) (\($0))" } ?? item.title
        ctx.addTask(title, item.dueDate)
        added.insert(item.id)
        return true
    }

    func addChecked() {
        let fresh = items.filter { checked.contains($0.id) }.map(add).filter { $0 }.count
        if fresh > 0 { celebrations += 1 }
    }

    /// Home card: find action items in what's on the clipboard, then open the panel to review them.
    func findInClipboard() -> Bool {
        guard let clip = AIClipboard.read(), !clip.isEmpty else { return false }
        input = clip
        find()
        ctx.openPanel(id)
        return true
    }

    /// The Home card's status line.
    var homeLine: String {
        switch request.phase {
        case .working, .failed:
            return request.phase.homeLine(idle: "")
        case .done where unreadable:
            return "Claude's answer wasn't a list. Open to try again."
        case .done where items.isEmpty:
            return "No action items in the last notes"
        default:
            guard !items.isEmpty else { return "Copy meeting notes, then click" }
            let inTasks = items.filter { added.contains($0.id) }.count
            return "\(items.count) found" + (inTasks == items.count ? ", all in Tasks" : inTasks > 0 ? ", \(inTasks) in Tasks" : "")
        }
    }

    var pendingChecked: Int { items.filter { checked.contains($0.id) && !added.contains($0.id) }.count }

    func copyList() {
        let chosen = items.filter { checked.contains($0.id) }
        AIClipboard.write(AILogic.actionItemsList(chosen.isEmpty ? items : chosen))
    }

    func stop() { request.cancel() }

    var homeCard: AnyView? {
        let allIn = !items.isEmpty && items.allSatisfy { added.contains($0.id) }
        return AnyView(AIHomeCard(scene: .actionItems, label: "Action items", title: aiClipboardTitle("to-dos"),
                                  line: homeLine, busy: request.isWorking, mood: allIn ? .happy : .normal,
                                  open: { self.ctx.openPanel(self.id) }) {
            AIClipboardButton(title: "Find to-dos", run: { self.findInClipboard() }, open: { self.ctx.openPanel(self.id) })
                .disabled(request.isWorking)
        })
    }

    var panel: AnyView { AnyView(ActionItemsPanel(module: self)) }
}

struct ActionItemsPanel: View {
    @Bindable var module: ActionItemsAddOn
    @State private var copied = false
    /// Orbit celebrates for a moment after items go to Tasks.
    @State private var celebrating = false
    @State private var cheerTask: Task<Void, Never>?

    private var allAdded: Bool { !module.items.isEmpty && module.items.allSatisfy { module.added.contains($0.id) } }

    private func cheer() {
        celebrating = true
        cheerTask?.cancel()
        cheerTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            celebrating = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Action items", subtitle: "Who does what, and by when",
                        tint: AddOnCategory.ai.tint)
            HStack(spacing: 12) {
                AIInputBox(text: $module.input, placeholder: "Paste meeting notes or a transcript", label: "Notes") {
                    PillButton(title: "Find items") { module.find() }
                        .disabled(module.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.request.isWorking
                                  || !ClaudeAPI.isConfigured)
                }
                .frame(width: 280)
                result
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glassCard(18)
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch module.request.phase {
        case .working:
            AIWorkingView(scene: .actionItems) { module.request.cancel() }
        case .failed(let message):
            AIErrorView(message: message) { module.find() }
        case .idle:
            if ClaudeAPI.isConfigured {
                AIHintView(scene: .actionItems, text: "Paste your notes and Orbit picks out who does what.")
            } else {
                AINoKeyView()
            }
        case .done:
            if module.unreadable {
                AIErrorView(message: "Claude's answer wasn't a list I could read.") { module.find() }
            } else if module.items.isEmpty {
                VStack(spacing: 12) {
                    OrbitView(size: 46, mood: .happy, motion: .idle)
                    Text("No action items in these notes. Nothing to do!")
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OrbitView(size: celebrating ? 24 : 18, mood: allAdded || celebrating ? .happy : .normal,
                          motion: celebrating ? .celebrate : .idle)
                    .frame(width: 24, height: 18)
                CardLabel("\(module.items.count) action items")
                Spacer(minLength: 0)
                if celebrating || allAdded {
                    Text(celebrating ? "Added to Tasks!" : "All in Tasks")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.live)
                        .transition(.opacity)
                }
            }
            .animation(Tokens.spring, value: celebrating)
            .onChange(of: module.celebrations) { _, _ in cheer() }
            NotchScroll {
                VStack(spacing: 4) {
                    ForEach(module.items) { item in row(item) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 6) {
                PillButton(title: module.pendingChecked > 0 ? "Add \(module.pendingChecked) to Tasks" : "Added to Tasks") {
                    module.addChecked()
                }
                .disabled(module.pendingChecked == 0)
                GlassPillButton(title: copied ? "Copied" : "Copy as list", symbol: copied ? "checkmark" : "doc.on.doc") {
                    module.copyList()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ item: AILogic.ActionItem) -> some View {
        let on = module.checked.contains(item.id)
        let isAdded = module.added.contains(item.id)
        return HStack(alignment: .top, spacing: 9) {
            Button { module.toggle(item.id) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? AddOnCategory.ai.tint : Tokens.faint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5)).foregroundStyle(on ? .white : Tokens.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let meta = [item.owner, item.dueDate.map { "Due " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }]
                    .compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { module.addToTasks(item) } label: {
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isAdded ? Tokens.live : .white)
                    .frame(width: 24, height: 24)
                    .glassSurface(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .help(isAdded ? "Added to Tasks" : "Add to Tasks")
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
