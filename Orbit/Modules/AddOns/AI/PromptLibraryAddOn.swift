import SwiftUI

/// Saved prompts with {{clipboard}} and {{date}} placeholders: copy them filled in, or run them with Claude.
@MainActor
@Observable
final class PromptLibraryAddOn: AddOnModule {
    let id = "addon.prompts"
    let title = "Prompts"
    let symbol = "text.book.closed"
    let addOn = AddOnInfo(category: .ai, tier: .free, summary: "Your saved prompts, filled with your clipboard and today's date, one click away.")

    struct SavedPrompt: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var text: String
    }

    static let starters: [SavedPrompt] = [
        .init(title: "Reply to an email",
              text: "Write a short, friendly reply to this email. Answer every question and keep my tone:\n\n{{clipboard}}"),
        .init(title: "Explain simply",
              text: "Explain this in plain words, as if to a smart friend who is new to the topic:\n\n{{clipboard}}"),
        .init(title: "Proofread",
              text: "Fix spelling and grammar in this text. Keep the language and my style. Reply with the corrected text only:\n\n{{clipboard}}"),
        .init(title: "Plan my day",
              text: "Today is {{date}}. Turn these notes into a short, ordered plan for the day with rough times:\n\n{{clipboard}}"),
        .init(title: "Meeting agenda",
              text: "Write a clear 30-minute meeting agenda for this topic, with minutes per item and a goal at the top:\n\n{{clipboard}}"),
    ]

    private(set) var prompts: [SavedPrompt]
    var selectedID: UUID?
    let request = AIRequest()
    /// The prompt the current answer belongs to.
    private(set) var answerFor: UUID?
    var savedNote = false
    private let ctx: AddOnContext
    private var saveTask: Task<Void, Never>?

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        prompts = Storage.load([SavedPrompt].self, from: "addon-prompts") ?? Self.starters
        selectedID = prompts.first?.id
        if ModuleRegistry.isPreview, prompts.count > 1 {
            selectedID = prompts[1].id
            answerFor = prompts[1].id
            request.preview("""
            A notch app puts small tools in the black area at the top of your MacBook screen. \
            Instead of opening a window, you hover or click there and the tool slides out: your next meeting, \
            a timer, music, or a quick question for Claude.
            """)
        }
    }

    var selected: SavedPrompt? { prompts.first { $0.id == selectedID } }

    func select(_ id: UUID) {
        guard id != selectedID else { return }
        selectedID = id
        if answerFor != id { request.reset(); answerFor = nil }
    }

    func update(_ id: UUID, title: String? = nil, text: String? = nil) {
        guard let i = prompts.firstIndex(where: { $0.id == id }) else { return }
        if let title { prompts[i].title = title }
        if let text { prompts[i].text = text }
        scheduleSave()
    }

    func add() {
        let prompt = SavedPrompt(title: "New prompt", text: "{{clipboard}}")
        prompts.append(prompt)
        select(prompt.id)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let i = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts.remove(at: i)
        if selectedID == id {
            selectedID = prompts.isEmpty ? nil : prompts[min(i, prompts.count - 1)].id
            request.reset(); answerFor = nil
        }
        scheduleSave()
    }

    /// The prompt's text with placeholders filled in from the clipboard and today's date.
    func filled(_ prompt: SavedPrompt) -> String {
        AILogic.fillPlaceholders(prompt.text, clipboard: AIClipboard.read() ?? "", date: .now)
    }

    func copy(_ prompt: SavedPrompt) { AIClipboard.write(filled(prompt)) }

    func run(_ prompt: SavedPrompt) {
        let text = filled(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answerFor = prompt.id
        savedNote = false
        request.run(system: AILogic.promptSystem, message: text, maxTokens: 2000)
    }

    func saveNote(_ answer: String) {
        let heading = selected?.title ?? "Prompt"
        ctx.addNote("\(heading)\n\n\(answer)")
        savedNote = true
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Storage.save(self.prompts, to: "addon-prompts")
        }
    }

    func stop() {
        request.cancel()
        if saveTask != nil {
            saveTask?.cancel()
            Storage.save(prompts, to: "addon-prompts")
        }
    }

    /// The prompts on the Home card: the first three in your list.
    var homePrompts: [SavedPrompt] { Array(prompts.prefix(3)) }

    /// Home card: opens the library.
    func openLibrary() { ctx.openPanel(id) }

    var homeCard: AnyView? { AnyView(PromptsHomeCard(module: self)) }

    var panel: AnyView { AnyView(PromptLibraryPanel(module: self)) }
}

/// Home: Orbit and your first three prompts. A click copies the prompt filled in with your
/// clipboard and today's date (nothing is sent to Claude); the arrow opens the library.
private struct PromptsHomeCard: View {
    let module: PromptLibraryAddOn
    @State private var copiedID: UUID?

    var body: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CardLabel("Prompts")
                    Spacer(minLength: 0)
                    Text(copiedID == nil ? "Click one to copy it, filled in" : "Copied with your clipboard and date")
                        .font(.system(size: 10.5)).foregroundStyle(copiedID == nil ? Tokens.faint : Tokens.live)
                    Button { module.openLibrary() } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Open Prompts")
                }
                HStack(spacing: 10) {
                    OrbitView(size: 30, motion: module.request.isWorking ? .thinking : .idle,
                              gaze: module.request.isWorking ? nil : CGVector(dx: 0.9, dy: 0.3))
                    if module.homePrompts.isEmpty {
                        Text("No prompts yet. Open Prompts to make one.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    } else {
                        // As many chips as fit, in your order.
                        ViewThatFits(in: .horizontal) {
                            ForEach((1...module.homePrompts.count).reversed(), id: \.self) { n in
                                HStack(spacing: 6) { ForEach(module.homePrompts.prefix(n)) { chip($0) } }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(_ prompt: PromptLibraryAddOn.SavedPrompt) -> some View {
        let copied = copiedID == prompt.id
        return Button {
            module.copy(prompt)
            copiedID = prompt.id
            Task { try? await Task.sleep(for: .seconds(1.4)); if copiedID == prompt.id { copiedID = nil } }
        } label: {
            HStack(spacing: 4) {
                if copied { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.live) }
                Text(prompt.title.isEmpty ? "Untitled" : prompt.title).font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassSurface(Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy, filled in with your clipboard and today's date")
    }
}

struct PromptLibraryPanel: View {
    let module: PromptLibraryAddOn
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Prompts", subtitle: "Use {{clipboard}} and {{date}} in any prompt",
                        tint: AddOnCategory.ai.tint)
            HStack(spacing: 12) {
                sidebar.frame(width: 178)
                if let prompt = module.selected {
                    editor(prompt)
                } else {
                    AIHintView(scene: .prompt, text: "No prompts yet. Make one with New prompt.")
                        .glassCard(18)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchScroll {
                VStack(spacing: 2) {
                    ForEach(module.prompts) { prompt in
                        let on = prompt.id == module.selectedID
                        Button { module.select(prompt.id) } label: {
                            Text(prompt.title.isEmpty ? "Untitled" : prompt.title)
                                .font(.system(size: 12, weight: on ? .medium : .regular))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Tokens.surface2 : .clear))
                                .foregroundStyle(on ? .white : Tokens.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { module.delete(prompt.id) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Button { module.add() } label: {
                Label("New prompt", systemImage: "plus").font(.system(size: 12))
                    .foregroundStyle(Tokens.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .frame(maxHeight: .infinity)
        .glassCard(18)
    }

    @ViewBuilder private func editor(_ prompt: PromptLibraryAddOn.SavedPrompt) -> some View {
        let showsAnswer = module.request.phase != .idle
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: Binding(get: { prompt.title }, set: { module.update(prompt.id, title: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            TextEditor(text: Binding(get: { prompt.text }, set: { module.update(prompt.id, text: $0) }))
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5).padding(.vertical, 6)
                .frame(maxHeight: .infinity)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
            HStack(spacing: 6) {
                Button { module.delete(prompt.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.secondary)
                        .frame(width: 28, height: 28).glassSurface(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Delete prompt")
                if !ClaudeAPI.isConfigured {
                    HStack(spacing: 6) {
                        OrbitView(size: 18, mood: .wide, motion: .idle)
                        Text("Connect Claude in Settings → Accounts to run prompts")
                            .font(.system(size: 10.5)).foregroundStyle(Tokens.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                GlassPillButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") {
                    module.copy(prompt)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }
                PillButton(title: "Run") { module.run(prompt) }
                    .disabled(module.request.isWorking || !ClaudeAPI.isConfigured)
                    .opacity(ClaudeAPI.isConfigured ? 1 : 0.5)
            }
            if showsAnswer {
                answer.frame(height: 176)
            }
        }
    }

    @ViewBuilder private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch module.request.phase {
            case .working:
                HStack(spacing: 10) {
                    AIOrbitScene(scene: .prompt, busy: true, size: 34)
                    Text(AIScene.prompt.workingText).font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                    Spacer(minLength: 0)
                    GlassPillButton(title: "Cancel", symbol: "stop.fill") { module.request.cancel() }
                }
                .frame(maxHeight: .infinity)
            case .failed(let message):
                AIErrorView(message: message) { if let p = module.selected { module.run(p) } }
            case .done(let text):
                AIResultLabel(text: "Answer")
                AIResultText(text: text).frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 6) {
                    AICopyButton { text }
                    GlassPillButton(title: module.savedNote ? "Saved" : "Save as note",
                                    symbol: module.savedNote ? "checkmark" : "note.text.badge.plus") { module.saveNote(text) }
                        .disabled(module.savedNote)
                    Spacer(minLength: 0)
                    Button { module.request.reset() } label: {
                        Text("Close").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                    }
                    .buttonStyle(.plain)
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(18)
    }
}
