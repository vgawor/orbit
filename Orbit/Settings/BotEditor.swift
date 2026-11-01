import SwiftUI

/// Settings → Bots → New bot / Edit: a bot's name, colour, job and tools.
struct BotEditorSheet: View {
    let store: BotStore
    let isNew: Bool
    @State var draft: Bot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("In one line, what it does", text: $draft.summary)
                    LabeledContent("Colour") {
                        HStack(spacing: 6) {
                            ForEach(Appearance.companions) { c in
                                Button { draft.color = c.id } label: {
                                    OrbitView(size: 26, motion: .still, colors: c)
                                        .padding(3)
                                        .background(Circle().strokeBorder(draft.color == c.id ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .help(c.name)
                            }
                        }
                    }
                }
                Section("Its job") {
                    TextEditor(text: $draft.job)
                        .font(.system(size: 12.5))
                        .frame(minHeight: 150)
                    Text("Write it like a note to a new colleague: what to look at, what to do, and what the report should look like. Orbit adds its own rules (asking before changes, keeping things short).")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("First message of each run", text: $draft.kickoff)
                }
                Section("What it may use") {
                    ForEach(BotGallery.toolGroups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.tools, id: \.name) { tool in
                                Toggle(tool.label, isOn: binding(tool.name))
                            }
                        }
                    }
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add bot" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.job.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
    }

    private var notes: String {
        var lines = ["Every bot also has its own memory."]
        let names = Set(draft.toolNames)
        if names.contains(where: { BotGate.kind(of: $0) == .write }) {
            lines.append("Changes wait for your OK in the notch.")
        }
        if names.contains("find_emails") || names.contains("read_email") {
            lines.append("Mail is read from Apple Mail on this Mac, so only while it's awake.")
        }
        if names.contains(Bot.webTool) {
            lines.append("Web searches cost extra (about 1–2.5 ¢ each) and count towards the bot's caps.")
        }
        return lines.joined(separator: " ")
    }

    private func binding(_ tool: String) -> Binding<Bool> {
        Binding(get: { draft.toolNames.contains(tool) }, set: { on in
            var t = Set(draft.toolNames)
            if on { t.insert(tool) } else { t.remove(tool) }
            t.formUnion(OrbitTools.memoryNames)
            draft.tools = Array(t).sorted()
        })
    }

    private func save() {
        var bot = draft
        bot.name = bot.name.trimmingCharacters(in: .whitespaces)
        if bot.summary.trimmingCharacters(in: .whitespaces).isEmpty { bot.summary = "Your own bot" }
        // A bot that can change things needs Draft, so you can approve each change.
        let changes = bot.toolNames.contains { BotGate.kind(of: $0) == .write }
        if changes && bot.level == .read { bot.level = .draft }
        if !changes && bot.level != .read { bot.level = .read }
        if isNew {
            store.add(bot)
        } else {
            store.update(bot.id) { saved in
                saved.name = bot.name; saved.summary = bot.summary; saved.color = bot.color
                saved.job = bot.job; saved.kickoff = bot.kickoff; saved.tools = bot.tools; saved.level = bot.level
                saved.trusted = saved.trusted?.filter { bot.toolNames.contains($0) }
            }
        }
        dismiss()
    }
}

/// Settings → Bots → Gallery: ready-made bots to add.
struct BotGallerySheet: View {
    let store: BotStore
    var startFromScratch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a bot").font(.title2.weight(.semibold))
            Text("Each one becomes your own bot: change its job, tools and schedule afterwards. Added bots start switched off.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(BotGallery.templates) { t in card(t) }
                    Button {
                        dismiss()
                        startFromScratch()
                    } label: {
                        HStack(spacing: 12) {
                            OrbitView(size: 40, motion: .still, colors: Appearance.companion("dot"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start from scratch").font(.headline)
                                Text("Write the job yourself and pick what it may use.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }

    private func card(_ t: BotGallery.Template) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitView(size: 40, motion: .idle, colors: Appearance.companion(t.color))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).font(.headline)
                Text(t.summary).font(.callout)
                Text("\(t.uses) · \(t.schedule.label)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added.contains(t.id) {
                Label("Added", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
            } else {
                Button("Add") {
                    store.add(t.makeBot())
                    added.insert(t.id)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }
}
