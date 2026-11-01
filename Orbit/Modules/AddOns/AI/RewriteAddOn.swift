import SwiftUI

/// Rewrite text in a tone: clearer, shorter, friendlier, more formal, fixed spelling or bullets.
@MainActor
@Observable
final class RewriteAddOn: AddOnModule {
    let id = "addon.rewrite"
    let title = "Rewrite"
    let symbol = "pencil.and.scribble"
    let addOn = AddOnInfo(category: .ai, tier: .pro, summary: "Make text clearer, shorter, friendlier or more formal, or fix its spelling.")

    var input = ""
    var tone: AILogic.Tone {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: "addon.rewrite.tone") }
    }
    let request = AIRequest()
    var replacedClipboard = false
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        tone = UserDefaults.standard.string(forKey: "addon.rewrite.tone").flatMap(AILogic.Tone.init) ?? .clearer
        if ModuleRegistry.isPreview {
            tone = .friendlier
            input = "We can't do the meeting Thursday. Send new times."
            request.preview("Sorry, Thursday doesn't work for us after all. Could you send over a few new times that suit you? Thanks!")
        }
    }

    func rewrite() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replacedClipboard = false
        request.run(system: AILogic.rewriteSystem, message: AILogic.rewriteMessage(text, tone: tone), maxTokens: 3000)
    }

    func replaceClipboard(_ text: String) {
        AIClipboard.write(text)
        replacedClipboard = true
    }

    /// Home card: rewrite what's on the clipboard in the current tone. False when the clipboard has no text.
    func rewriteClipboard() -> Bool {
        guard let clip = AIClipboard.read(), !clip.isEmpty else { return false }
        input = clip
        rewrite()
        return true
    }

    func stop() { request.cancel() }

    var homeCard: AnyView? {
        AnyView(AIHomeCard(scene: .rewrite, label: "Rewrite", title: aiClipboardTitle(tone.title.lowercased()),
                           line: request.phase.homeLine(idle: "Pick another tone in the panel"),
                           busy: request.isWorking, open: { self.ctx.openPanel(self.id) }) {
            if let result = request.result {
                AIHomeIconButton(symbol: "arrow.triangle.2.circlepath", help: "Replace the clipboard with this") {
                    self.replaceClipboard(result)
                }
            }
            AIClipboardButton(title: "Rewrite", run: { self.rewriteClipboard() }, open: { self.ctx.openPanel(self.id) })
                .disabled(request.isWorking)
        })
    }

    var panel: AnyView { AnyView(RewritePanel(module: self)) }
}

struct RewritePanel: View {
    @Bindable var module: RewriteAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Rewrite", subtitle: "Same meaning, better words",
                        tint: AddOnCategory.ai.tint)
            AIChips(items: AILogic.Tone.allCases, selection: $module.tone) { $0.title }
            HStack(spacing: 12) {
                AIInputBox(text: $module.input, placeholder: "Paste text, or use what's on your clipboard") {
                    PillButton(title: "Rewrite") { module.rewrite() }
                        .disabled(module.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.request.isWorking
                                  || !ClaudeAPI.isConfigured)
                }
                .frame(width: 300)
                AIResultCard(request: module.request, label: module.tone.title, scene: .rewrite,
                             hint: "Pick a tone and Orbit finds better words.", retry: { module.rewrite() }) { text in
                    AICopyButton { text }
                    GlassPillButton(title: module.replacedClipboard ? "Clipboard replaced" : "Replace clipboard",
                                    symbol: module.replacedClipboard ? "checkmark" : "arrow.triangle.2.circlepath") {
                        module.replaceClipboard(text)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
