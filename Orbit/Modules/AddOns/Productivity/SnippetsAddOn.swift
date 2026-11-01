import AppKit
import SwiftUI

/// Saved bits of text (addresses, replies, links) one click away.
@MainActor
@Observable
final class SnippetsAddOn: AddOnModule {
    let id = "addon.snippets"
    let title = "Snippets"
    let symbol = "text.badge.plus"
    let addOn = AddOnInfo(category: .productivity, tier: .free,
                          summary: "Text you type again and again, one click from your clipboard.")

    struct Snippet: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var body: String
    }

    /// What the editor is working on: a new snippet (id not in the list yet) or an existing one.
    struct Draft: Equatable {
        var id = UUID()
        var title = ""
        var body = ""
        var isNew = true
    }

    private(set) var snippets: [Snippet] = []
    var draft: Draft?
    var query = ""
    private(set) var justCopied: UUID?

    private let ctx: AddOnContext
    private let storageKey: String?

    init(_ ctx: AddOnContext, storageKey: String? = "addon-snippets") {
        self.ctx = ctx
        self.storageKey = storageKey
        if let storageKey { snippets = Storage.load([Snippet].self, from: storageKey) ?? [] }
        if ModuleRegistry.isPreview && storageKey != nil { snippets = Self.sample }
    }

    // MARK: Pure logic

    /// A title for a snippet: what you typed, or the first words of the text.
    nonisolated static func title(_ title: String, body: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(5).joined(separator: " ")
        return words.isEmpty ? "Untitled" : words
    }

    nonisolated static func filtered(_ list: [Snippet], query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.body.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: Actions

    var visible: [Snippet] { Self.filtered(snippets, query: query) }

    func newSnippet() { draft = Draft() }

    func edit(_ s: Snippet) { draft = Draft(id: s.id, title: s.title, body: s.body, isNew: false) }

    /// Saves the open draft. Empty text is not saved.
    func saveDraft() {
        guard let d = draft else { return }
        guard !d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let snippet = Snippet(id: d.id, title: Self.title(d.title, body: d.body), body: d.body)
        if let i = snippets.firstIndex(where: { $0.id == d.id }) { snippets[i] = snippet } else { snippets.insert(snippet, at: 0) }
        draft = nil
        save()
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        if draft?.id == id { draft = nil }
        save()
    }

    func copy(_ s: Snippet) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s.body, forType: .string)
        justCopied = s.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.justCopied == s.id { self?.justCopied = nil }
        }
    }

    private func save() {
        guard let storageKey else { return }
        Storage.save(snippets, to: storageKey)
    }

    // MARK: Views

    var panel: AnyView { AnyView(SnippetsPanel(module: self)) }

    /// Your first few snippets, one click to copy. Hidden until you have some.
    var homeCard: AnyView? {
        guard !snippets.isEmpty else { return nil }
        return AnyView(SnippetsHomeCard(module: self).contentShape(Rectangle())
            .onTapGesture { [ctx, id] in ctx.openPanel(id) })
    }

    /// Orbit in the header: writing along while you edit, delighted when a snippet is copied.
    nonisolated static func orbit(editing: Bool, copied: Bool) -> ProductivityOrbit {
        if copied { return ProductivityOrbit(mood: .happy, motion: .celebrate) }
        if editing { return ProductivityOrbit(mood: .squint, motion: .working) }
        return .calm
    }
    var orbit: ProductivityOrbit { Self.orbit(editing: draft != nil, copied: justCopied != nil) }

    /// Starter snippets, with your own name and company in the sign-off.
    private static var sample: [Snippet] {
        let signOff = ["Best regards,", UserProfile.fullName, UserProfile.company].filter { !$0.isEmpty }.joined(separator: "\n")
        return [
            Snippet(title: "Email sign-off", body: signOff),
            Snippet(title: "Thanks reply", body: "Thanks for getting back to me! I'll take a look and reply by the end of the day."),
            Snippet(title: "Meeting link", body: "Paste your personal meeting link here"),
        ]
    }
}

// MARK: - Panel

private struct SnippetsPanel: View {
    let module: SnippetsAddOn

    var body: some View {
        @Bindable var module = module
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AddOnHeader(symbol: module.symbol, title: "Snippets",
                            subtitle: module.snippets.isEmpty ? "Save text you use a lot" : "Click one to copy it",
                            tint: ProductivityAddOns.tint)
                if !module.snippets.isEmpty {
                    ProductivityOrbitView(look: module.orbit, size: 34)
                }
                if !module.snippets.isEmpty {
                    ProductivityField(placeholder: "Search", text: $module.query, symbol: "magnifyingglass").frame(width: 180)
                }
                PillButton(title: "New snippet") { withAnimation(Tokens.spring) { module.newSnippet() } }
            }
            HStack(alignment: .top, spacing: 12) {
                listCard
                if module.draft != nil {
                    SnippetEditor(module: module)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Tokens.spring, value: module.draft != nil)
        }
    }

    private var listCard: some View {
        let list = module.visible
        let columns = module.draft == nil ? 2 : 1
        return NotchScroll {
            VStack(alignment: .leading, spacing: 8) {
                if list.isEmpty {
                    VStack(spacing: 8) {
                        OrbitView(size: 60, mood: .happy, motion: .idle)
                        Text(module.snippets.isEmpty ? "No snippets yet" : "No matches").font(.system(size: 13, weight: .semibold))
                        Text(module.snippets.isEmpty ? "Add an address, a link or a reply you type often." : "Try another word.")
                            .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 70)
                }
                ForEach(Array(stride(from: 0, to: list.count, by: columns)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(list[start..<min(start + columns, list.count)]) { SnippetTile(snippet: $0, module: module) }
                        if columns == 2 && start + 1 >= list.count { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
    }
}

private struct SnippetsHomeCard: View {
    let module: SnippetsAddOn

    var body: some View {
        NotchCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        CardLabel("Snippets")
                        Text("Click to copy").font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                    }
                    HStack(spacing: 6) {
                        ForEach(module.snippets.prefix(3)) { SnippetChip(snippet: $0, module: module) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProductivityOrbitView(look: module.orbit, size: 40)
            }
        }
    }
}

/// A snippet as a small pill on the Home card: copies on click and says so.
private struct SnippetChip: View {
    let snippet: SnippetsAddOn.Snippet
    let module: SnippetsAddOn
    @State private var hovering = false

    var body: some View {
        let copied = module.justCopied == snippet.id
        Button { module.copy(snippet) } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(copied ? Tokens.live : Tokens.secondary)
                Text(snippet.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .glassSurface(Capsule(), selected: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(snippet.body)
    }
}

private struct SnippetTile: View {
    let snippet: SnippetsAddOn.Snippet
    let module: SnippetsAddOn
    @State private var hovering = false

    var body: some View {
        let copied = module.justCopied == snippet.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(snippet.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if copied {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.live)
                } else if hovering {
                    ProductivityIconButton(symbol: "pencil", help: "Edit") { module.edit(snippet) }
                        .frame(height: 16)
                }
            }
            Text(snippet.body).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(hovering || module.draft?.id == snippet.id ? 0.11 : 0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { module.copy(snippet) }
        .help("Click to copy")
        .contextMenu {
            Button("Copy") { module.copy(snippet) }
            Button("Edit") { module.edit(snippet) }
            Button("Delete", role: .destructive) { module.delete(snippet.id) }
        }
    }
}

private struct SnippetEditor: View {
    let module: SnippetsAddOn

    var body: some View {
        let draft = Binding(get: { module.draft ?? .init() }, set: { module.draft = $0 })
        VStack(alignment: .leading, spacing: 10) {
            CardLabel(draft.wrappedValue.isNew ? "New snippet" : "Edit snippet")
            TextField("Title", text: draft.title)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface))
            TextEditor(text: draft.body)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface))
            HStack(spacing: 8) {
                if !draft.wrappedValue.isNew {
                    ProductivityIconButton(symbol: "trash", tint: Tokens.error, help: "Delete") {
                        withAnimation(Tokens.spring) { module.delete(draft.wrappedValue.id) }
                    }
                }
                Spacer()
                GlassPillButton(title: "Cancel") { withAnimation(Tokens.spring) { module.draft = nil } }
                PillButton(title: "Save") { withAnimation(Tokens.spring) { module.saveDraft() } }
                    .opacity(draft.wrappedValue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), selected: true)
    }
}
