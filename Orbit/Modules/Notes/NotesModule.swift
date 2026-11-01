import SwiftUI

/// A scratchpad plus a short list of notes. Saved to ~/Library/Application Support/Orbit/notes.json.
@MainActor
@Observable
final class NotesModule: NotchModule {
    let id = "notes"
    let title = "Notes"
    let symbol = "note.text"

    struct Note: Codable, Identifiable, Equatable {
        var id = UUID()
        var body: String
        var updated = Date.now

        var title: String {
            let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return first.isEmpty ? "New note" : first
        }
    }

    private(set) var notes: [Note]
    var selectedID: UUID?
    private let openPanel: @MainActor (String) -> Void
    private var saveTask: Task<Void, Never>?

    init(openPanel: @escaping @MainActor (String) -> Void) {
        self.openPanel = openPanel
        notes = Storage.load([Note].self, from: "notes") ?? [Note(body: "Scratchpad\n")]
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func update(_ id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].body != body else { return }
        notes[i].body = body
        notes[i].updated = .now
        scheduleSave()
    }

    func add() {
        let note = Note(body: "")
        notes.insert(note, at: min(1, notes.count)) // keep the scratchpad on top
        selectedID = note.id
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard notes.count > 1 else { return }
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
        scheduleSave()
    }

    /// Saves half a second after the last keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Storage.save(self.notes, to: "notes")
        }
    }

    func stop() {
        saveTask?.cancel()
        Storage.save(notes, to: "notes")
    }

    // MARK: Views

    var homeCard: AnyView? {
        AnyView(Button { self.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    CardLabel("Notes")
                    Text(notes.first?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.secondary)
                        .lineLimit(7)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(NotesPanel(module: self)) }
}

struct NotesPanel: View {
    let module: NotesModule
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(module.notes) { note in
                            Button { module.selectedID = note.id } label: {
                                Text(note.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 9)
                                        .fill(module.selectedID == note.id ? Tokens.surface2 : .clear))
                                    .foregroundStyle(module.selectedID == note.id ? .white : Tokens.secondary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", role: .destructive) { module.delete(note.id) }
                            }
                        }
                    }
                }
                Button { module.add() } label: {
                    Label("New note", systemImage: "plus").font(.system(size: 12))
                        .foregroundStyle(Tokens.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 160)

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.stroke))
                .onChange(of: text) { _, new in
                    if let id = module.selectedID { module.update(id, body: new) }
                }
        }
        .onAppear { text = module.selected?.body ?? "" }
        .onChange(of: module.selectedID) { _, _ in text = module.selected?.body ?? "" }
    }
}
