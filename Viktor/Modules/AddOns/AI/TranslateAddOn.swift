import SwiftUI

/// Translate text into one of 14 languages; the source language is detected.
@MainActor
@Observable
final class TranslateAddOn: AddOnModule {
    let id = "addon.translate"
    let title = "Translate"
    let symbol = "character.bubble"
    let addOn = AddOnInfo(category: .ai, tier: .pro, summary: "Translate text into 14 languages, keeping its formatting.")

    var input = ""
    var target: String {
        didSet { UserDefaults.standard.set(target, forKey: "addon.translate.target") }
    }
    /// Detected source language of the last translation.
    var detected: String?
    /// The translation without the "SOURCE:" line.
    var translation: String?
    let request = AIRequest()
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        let saved = UserDefaults.standard.string(forKey: "addon.translate.target")
        target = saved.flatMap { AILogic.languages.contains($0) ? $0 : nil } ?? "English"
        if ModuleRegistry.isPreview {
            input = "Hej Anna!\n\nTack för mötet i går. Jag skickar offerten på fredag.\n\nVänliga hälsningar,\nViktor"
            detected = "Swedish"
            translation = "Hi Anna!\n\nThanks for the meeting yesterday. I'll send the quote on Friday.\n\nBest regards,\nViktor"
            request.preview(translation ?? "")
        }
    }

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        detected = nil
        translation = nil
        request.run(system: AILogic.translateSystem, message: AILogic.translateMessage(text, to: target), maxTokens: 4000) { [weak self] raw in
            let parsed = AILogic.parseTranslation(raw)
            self?.detected = parsed.source
            self?.translation = parsed.text
            return parsed.text
        }
    }

    /// Puts the translation in the box and translates back into the detected language next time.
    func swap() {
        guard let translation else { return }
        let back = AILogic.knownLanguage(detected)
        input = translation
        if let back { target = back }
        detected = nil
        self.translation = nil
        request.reset()
    }

    /// Home card: translate what's on the clipboard into the current language. False when the clipboard has no text.
    func translateClipboard() -> Bool {
        guard let clip = AIClipboard.read(), !clip.isEmpty else { return false }
        input = clip
        translate()
        return true
    }

    func stop() { request.cancel() }

    var homeCard: AnyView? {
        let idle = "Copy text in any language, then click"
        let line = request.result != nil
            ? (detected.map { "From \($0): " } ?? "") + request.phase.homeLine(idle: idle)
            : request.phase.homeLine(idle: idle)
        return AnyView(AIHomeCard(scene: .translate, label: "Translate", title: aiClipboardTitle(target),
                                  line: line, busy: request.isWorking, open: { self.ctx.openPanel(self.id) }) {
            if let translation { AIHomeCopyButton(text: translation) }
            AIClipboardButton(title: "Translate", run: { self.translateClipboard() },
                              open: { self.ctx.openPanel(self.id) })
                .disabled(request.isWorking)
        })
    }

    var panel: AnyView { AnyView(TranslatePanel(module: self)) }
}

struct TranslatePanel: View {
    @Bindable var module: TranslateAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Translate", subtitle: "Keeps line breaks, lists and names",
                        tint: AddOnCategory.ai.tint)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 11))
                    Text(module.detected.map { "From \($0)" } ?? "Detect language")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(module.detected == nil ? Tokens.secondary : .white)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .glassSurface(Capsule())

                Button { module.swap() } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(module.translation == nil ? Tokens.faint : .white)
                        .frame(width: 28, height: 28).glassSurface(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(module.translation == nil).help("Swap")

                Menu {
                    ForEach(AILogic.languages, id: \.self) { lang in
                        Button { module.target = lang } label: {
                            if lang == module.target { Label(lang, systemImage: "checkmark") } else { Text(lang) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("To \(module.target)").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .glassSurface(Capsule(), selected: true, interactive: true)
                    .contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                AIInputBox(text: $module.input, placeholder: "Type or paste text in any language") {
                    PillButton(title: "Translate") { module.translate() }
                        .disabled(module.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.request.isWorking
                                  || !ClaudeAPI.isConfigured)
                }
                .frame(width: 300)
                AIResultCard(request: module.request, label: module.target, scene: .translate,
                             hint: "Write in any language. Orbit works out which one.", retry: { module.translate() },
                             header: { _ in EmptyView() }) { _ in
                    AICopyButton { module.translation ?? "" }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

