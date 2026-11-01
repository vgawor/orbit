import SwiftUI

/// Summarize pasted or copied text in three lengths.
@MainActor
@Observable
final class SummarizeAddOn: AddOnModule {
    let id = "addon.summarize"
    let title = "Summarize"
    let symbol = "text.redaction"
    let addOn = AddOnInfo(category: .ai, tier: .pro, summary: "Turn long text into three bullets, a paragraph or a detailed summary.")

    var input = ""
    var length: AILogic.SummaryLength {
        didSet { UserDefaults.standard.set(length.rawValue, forKey: "addon.summarize.length") }
    }
    let request = AIRequest()
    private let ctx: AddOnContext
    var savedNote = false

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        length = UserDefaults.standard.string(forKey: "addon.summarize.length").flatMap(AILogic.SummaryLength.init) ?? .bullets
        // Layout snapshots show the "no key" state with some text in the box.
        if ModuleRegistry.isPreview {
            input = "Q3 review with Northwind: revenue up 12% to 4.2 MSEK, two new municipalities signed…"
        }
    }

    func summarize() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        savedNote = false
        request.run(system: AILogic.summarizeSystem, message: AILogic.summarizeMessage(text, length: length))
    }

    func saveNote(_ text: String) {
        ctx.addNote("Summary\n\n" + text)
        savedNote = true
    }

    /// Home card: summarize what's on the clipboard. False when the clipboard has no text.
    func summarizeClipboard() -> Bool {
        guard let clip = AIClipboard.read(), !clip.isEmpty else { return false }
        input = clip
        summarize()
        return true
    }

    func stop() { request.cancel() }

    var homeCard: AnyView? {
        AnyView(AIHomeCard(scene: .summarize, label: "Summarize", title: aiClipboardTitle(length.title.lowercased()),
                           line: request.phase.homeLine(idle: "Copy something long, then click"),
                           busy: request.isWorking, open: { self.ctx.openPanel(self.id) }) {
            if let result = request.result { AIHomeCopyButton(text: result) }
            AIClipboardButton(title: "Summarize", run: { self.summarizeClipboard() },
                              open: { self.ctx.openPanel(self.id) })
                .disabled(request.isWorking)
        })
    }

    var panel: AnyView { AnyView(SummarizePanel(module: self)) }
}

struct SummarizePanel: View {
    @Bindable var module: SummarizeAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Summarize", subtitle: "Plain words, names and numbers kept exact",
                        tint: AddOnCategory.ai.tint)
            AIChips(items: AILogic.SummaryLength.allCases, selection: $module.length) { $0.title }
            HStack(spacing: 12) {
                AIInputBox(text: $module.input, placeholder: "Paste text, or use what's on your clipboard") {
                    PillButton(title: "Summarize") { module.summarize() }
                        .disabled(module.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.request.isWorking
                                  || !ClaudeAPI.isConfigured)
                }
                .frame(width: 300)
                AIResultCard(request: module.request, label: "Summary", scene: .summarize,
                             hint: "Orbit squeezes long text down to what matters.", retry: { module.summarize() }) { text in
                    AICopyButton { text }
                    GlassPillButton(title: module.savedNote ? "Saved" : "Save as note",
                                    symbol: module.savedNote ? "checkmark" : "note.text.badge.plus") {
                        module.saveNote(text)
                    }
                    .disabled(module.savedNote)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
