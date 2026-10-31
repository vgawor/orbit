import SwiftUI

/// Settings → Bots: turn bots on, set when they run, what they may do and what a run may cost.
struct BotsSettings: View {
    let module: BotsModule?
    @AppStorage(BotsSettings.galleryKey) private var openGallery = false
    @State private var showGallery = false
    @State private var editing: Bot?
    @State private var newBot: Bot?

    /// Set by the notch's "Add a bot" button, so Settings opens on the gallery.
    static let galleryKey = "bots.openGallery"

    var body: some View {
        form
            .onAppear(perform: checkGallery)
            .onChange(of: openGallery) { checkGallery() }
            .sheet(isPresented: $showGallery) {
                if let store = module?.store {
                    BotGallerySheet(store: store) { newBot = BotGallery.blank() }
                }
            }
            .sheet(item: $editing) { bot in
                if let store = module?.store { BotEditorSheet(store: store, isNew: false, draft: bot) }
            }
            .sheet(item: $newBot) { bot in
                if let store = module?.store { BotEditorSheet(store: store, isNew: true, draft: bot) }
            }
    }

    private func checkGallery() {
        guard openGallery else { return }
        openGallery = false
        showGallery = true
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    OrbitView(size: 40, motion: .still, colors: Appearance.companion("sunny"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bots are AI teammates that run in Anthropic's cloud on a schedule, even when your Mac sleeps, and come back to you in the notch.")
                        Text("They can't change anything on their own: every tool they use asks Orbit, and changes wait for your OK in the notch (Send, Edit or Skip).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if OrbitCloud.shared.usesPro {
                    LabeledContent("Keys") { Text("Orbit Pro: bots use Orbit's keys").foregroundStyle(.secondary) }
                }
                LabeledContent("Claude (Anthropic API key)") {
                    Text(ManagedAgentsAPI.isConfigured ? "Added in Accounts → Claude" : "Not added yet")
                        .foregroundStyle(ManagedAgentsAPI.isConfigured ? Color.secondary : Color.orange)
                }
                LabeledContent("ChatGPT (OpenAI API key)") {
                    Text(OpenAIAPI.isConfigured ? "Added in Accounts → ChatGPT" : "Optional")
                        .foregroundStyle(.secondary)
                }
                Text("Tip: use keys with a monthly spend limit. Runs are billed to those keys. Claude bots run in the cloud, even when your Mac sleeps; ChatGPT bots run on this Mac while it's awake.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let module {
                Section {
                    HStack {
                        Text("\(module.store.bots.count) bots")
                        Spacer()
                        Button("Gallery…") { showGallery = true }
                        Button("New bot…") { newBot = BotGallery.blank() }
                    }
                }
                ForEach(module.store.bots) { bot in
                    BotSettingsSection(module: module, bot: bot) { editing = bot }
                }
            }

            Section("What leaves your Mac") {
                Text("When a bot asks, Orbit answers with only what that question needs: today's meetings and tasks, one meeting's attendees, matching notes, or HubSpot details for the people in a meeting. Nothing is synced in bulk, and nothing is shared while your Mac sleeps; the bot waits until you're back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BotSettingsSection: View {
    let module: BotsModule
    let bot: Bot
    var edit: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                HStack(spacing: 8) {
                    OrbitView(size: 26, mood: bot.enabled ? .normal : .closed, motion: .still, colors: Appearance.companion(bot.color))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(bot.name).font(.headline)
                        Text(bot.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(bot.engine == .claude ? !ManagedAgentsAPI.isConfigured : !OpenAIAPI.isConfigured)

            Picker("Runs with", selection: Binding(get: { bot.engine }, set: { module.store.setProvider(bot.id, $0) })) {
                ForEach(BotProvider.allCases) { Text($0.label).tag($0) }
            }
            if bot.engine == .chatgpt {
                Text(OpenAIAPI.isConfigured
                     ? "Runs on this Mac while it's awake. A run missed while it slept starts when you're back, if it's less than 12 hours late."
                     : "Add your OpenAI API key in Settings → Accounts → ChatGPT first. A ChatGPT subscription doesn't include API use.")
                    .font(.caption).foregroundStyle(OpenAIAPI.isConfigured ? Color.secondary : Color.orange)
            }

            Picker("Runs", selection: Binding(get: { bot.schedule.days }, set: { v in module.store.update(bot.id) { $0.schedule.days = v } })) {
                ForEach(BotSchedule.Days.allCases) { Text($0.label).tag($0) }
            }
            if bot.schedule.days == .weekly {
                Picker("On", selection: Binding(get: { bot.schedule.day }, set: { v in module.store.update(bot.id) { $0.schedule.weekday = v } })) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1].capitalized).tag(d) }
                }
            }
            if bot.schedule.days != .manual {
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
            if bot.id == Bot.chiefOfStaff.id {
                Toggle("Prepare me 10 minutes before meetings with other people", isOn: binding(\.prepMeetings))
            }
            Picker("May do on its own", selection: binding(\.level)) {
                ForEach(BotLevel.allCases) { level in
                    Text(level.label).tag(level).selectionDisabled(level != .read && level != .draft)
                }
            }
            Text("\(bot.level.detail) “Do, then tell” and “Do quietly” come in a later version of Orbit.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Model", selection: binding(\.model)) {
                ForEach(bot.engine.models, id: \.id) { Text($0.label).tag($0.id) }
            }
            if bot.engine == .claude {
                Stepper(value: Binding(get: { bot.budgetCents }, set: { v in module.store.update(bot.id) { $0.budgetCents = v } }),
                        in: 25...500, step: 25) {
                    LabeledContent("Spend cap per run", value: BotRunner.dollars(bot.budgetCents))
                }
            }
            Stepper(value: Binding(get: { bot.monthlyCap }, set: { v in module.store.update(bot.id) { $0.monthlyCapCents = v } }),
                    in: 500...20000, step: 500) {
                LabeledContent("Monthly cap", value: "\(BotRunner.dollars(module.runner.spent(bot.id))) of \(BotRunner.dollars(bot.monthlyCap)) this month")
            }
            if bot.engine == .chatgpt {
                Text("ChatGPT costs are estimated from OpenAI's list prices.").font(.caption).foregroundStyle(.secondary)
            }
            let trustable = bot.toolNames.filter { BotGate.trustable.contains($0) }
            if bot.level == .draft && !trustable.isEmpty {
                DisclosureGroup("Does on its own (\(bot.trustedTools.count))") {
                    ForEach(trustable, id: \.self) { tool in
                        Toggle(BotsModule.verb(tool).prefix(1).uppercased() + BotsModule.verb(tool).dropFirst(), isOn: Binding(
                            get: { bot.trustedTools.contains(tool) },
                            set: { on in module.store.update(bot.id) { b in
                                var t = Set(b.trusted ?? [])
                                if on { t.insert(tool) } else { t.remove(tool) }
                                b.trusted = Array(t).sorted()
                            } }))
                    }
                    Text("These happen without asking, then show in the notch with Undo for 10 minutes. Email drafts always ask. Orbit offers this after you've approved the same thing \(BotRunner.trustAfter) times without changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            BotMemoryEditor(memory: module.runner.memory, botID: bot.id)
            HStack {
                Button("Edit job and tools…", action: edit)
                if !bot.isBuiltIn {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .confirmationDialog("Remove \(bot.name)?", isPresented: $confirmRemove) {
                            Button("Remove", role: .destructive) {
                                Task { await module.store.remove(bot.id); module.runner.memory.clear(bot.id) }
                            }
                        } message: {
                            Text("Its schedule stops and its memory is deleted. Earlier reports stay in the history.")
                        }
                }
                Spacer()
            }
            HStack {
                Text(status).font(.caption).foregroundStyle(module.store.syncErrors[bot.id] == nil ? Color.secondary : Color.orange)
                Spacer()
                Button("Run now") { Task { await module.runner.runNow(bot.id) } }
                    .disabled(!bot.enabled || module.runner.isBusy(bot.id))
            }
        }
    }

    private var status: String {
        if let e = module.store.syncErrors[bot.id] { return e }
        if module.store.syncing.contains(bot.id) { return "Updating the cloud…" }
        if bot.engine == .chatgpt {
            let tokens = module.runner.runs(for: bot.id).filter { $0.started > .now.addingTimeInterval(-7 * 86400) }
                .compactMap(\.tokens).reduce(0, +)
            return "\(bot.enabled ? BotDetail.status(bot, module: module) : "Off") · \(tokens.formatted()) tokens this week"
        }
        guard bot.agentID != nil else { return bot.enabled ? "Not set up in the cloud yet." : "Off. Nothing runs and nothing is billed." }
        let spent = module.runner.runs(for: bot.id).filter { $0.started > .now.addingTimeInterval(-7 * 86400) }
            .compactMap(\.costCents).reduce(0, +)
        return "\(bot.enabled ? BotDetail.status(bot, module: module) : "Paused") · version \(bot.agentVersion ?? 1) · \(BotRunner.dollars(spent)) this week"
    }

    private func binding<V>(_ key: WritableKeyPath<Bot, V>) -> Binding<V> {
        Binding(get: { bot[keyPath: key] }, set: { v in
            if key == \Bot.enabled, let on = v as? Bool { module.toggle(bot.id, on: on) } else { module.store.update(bot.id) { $0[keyPath: key] = v } }
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: bot.schedule.hour, minute: bot.schedule.minute, second: 0, of: .now) ?? .now
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            module.store.update(bot.id) { $0.schedule.hour = c.hour ?? 8; $0.schedule.minute = c.minute ?? 0 }
        })
    }
}

/// A bot's memory: every note it keeps, editable, plus your own.
private struct BotMemoryEditor: View {
    let memory: BotMemory
    let botID: String
    @State private var newNote = ""

    var body: some View {
        let notes = memory.notes(for: botID)
        DisclosureGroup("Memory (\(notes.count))") {
            if notes.isEmpty {
                Text("Nothing yet. The bot writes down lasting facts here, like who approves deals or how you like your emails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline) {
                    TextField("Note", text: Binding(get: { note.text }, set: { memory.update(note.id, text: $0) }), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if note.source == .you { Text("You").font(.caption2).foregroundStyle(.secondary) }
                    Button { memory.delete(note.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Forget this")
                }
            }
            HStack {
                TextField("New note", text: $newNote, prompt: Text("Add something the bot should know…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !notes.isEmpty {
                Button("Forget everything", role: .destructive) { memory.clear(botID) }
                    .font(.caption)
            }
        }
    }

    private func add() {
        memory.add(newNote, for: botID, source: .you)
        newNote = ""
    }
}
