import SwiftUI

/// Create a HubSpot task with the same essentials as HubSpot's own form:
/// title, due date and time, type, priority, project, reminder and notes. Always assigned to you.
struct HubSpotTaskForm: View {
    let module: TasksModule
    let provider: HubSpotTaskProvider
    let initialText: String

    @State private var draft = HubSpotTaskProvider.Draft(due: HubSpotTaskForm.businessDays(3))
    @State private var projects: [HubSpotTaskProvider.Project] = []
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private static let types = [("TODO", "To-do"), ("CALL", "Call"), ("EMAIL", "Email")]
    private static let priorities = [("NONE", "None"), ("LOW", "Low"), ("MEDIUM", "Medium"), ("HIGH", "High")]
    private static let reminders: [(Int?, String)] = [
        (nil, "No reminder"), (0, "At due time"), (15, "15 min before"), (60, "1 hour before"), (1440, "1 day before"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header with actions
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(Color(red: 1, green: 0.48, blue: 0.35))
                Text("New HubSpot task").font(.system(size: 13, weight: .semibold))
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Tokens.error).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { module.composing = nil }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    .keyboardShortcut(.cancelAction)
                PillButton(title: saving ? "Creating…" : "Create", fill: canSave ? Color(red: 1, green: 0.48, blue: 0.35) : Tokens.surface2) {
                    save()
                }
                .disabled(!canSave)
            }

            // Title
            TextField("Task title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
                .focused($titleFocused)
                .onSubmit(save)

            // Due date: quick picks like HubSpot, plus exact date and time
            HStack(spacing: 6) {
                label("Due")
                ForEach(quickDates, id: \.0) { name, date in
                    Chip(title: name) { setDay(date) }
                }
                Spacer(minLength: 4)
                DatePicker("", selection: $draft.due, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .controlSize(.small)
                    .fixedSize()
            }

            // Type and priority
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    label("Type")
                    segmented(Self.types, $draft.type)
                }
                HStack(spacing: 6) {
                    label("Priority")
                    segmented(Self.priorities, $draft.priority)
                }
                Spacer()
            }

            // Project and reminder
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    label("Project")
                    Menu {
                        Button("No project") { draft.projectID = nil }
                        let mine = projects.filter(\.mine), other = projects.filter { !$0.mine }
                        if !mine.isEmpty {
                            Section("Your projects") { ForEach(mine) { p in Button(p.name) { draft.projectID = p.id } } }
                        }
                        if !other.isEmpty {
                            Section("Other projects") { ForEach(other) { p in Button(p.name) { draft.projectID = p.id } } }
                        }
                    } label: {
                        menuLabel(projects.first { $0.id == draft.projectID }?.name ?? "No project")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                HStack(spacing: 6) {
                    label("Reminder")
                    Menu {
                        ForEach(Self.reminders, id: \.1) { minutes, name in
                            Button(name) { draft.reminderMinutes = minutes }
                        }
                    } label: {
                        menuLabel(Self.reminders.first { $0.0 == draft.reminderMinutes }?.1 ?? "No reminder")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer()
                Text("Assigned to you").font(.system(size: 11)).foregroundStyle(Tokens.faint)
            }

            // Notes
            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
        }
        .onAppear {
            // Start from what was typed: "Call Anna tomorrow 14:00" fills the title and due date.
            let parsed = TaskParser.parse(initialText)
            draft.title = parsed.title
            if let due = parsed.due {
                draft.due = parsed.hasTime ? due : Self.at8(due)
            }
            titleFocused = true
        }
        .task {
            projects = (try? await provider.projects()) ?? []
        }
    }

    // MARK: Pieces

    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        Task {
            error = await module.createHubSpot(draft)
            saving = false
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.6)
            .foregroundStyle(Tokens.faint).frame(width: text.count > 6 ? 62 : 34, alignment: .leading)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.faint)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Tokens.surface2))
    }

    private func segmented(_ options: [(String, String)], _ value: Binding<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { key, name in
                Button(name) { value.wrappedValue = key }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(value.wrappedValue == key ? Color.white : .clear))
                    .foregroundStyle(value.wrappedValue == key ? Color.black : Tokens.secondary)
            }
        }
        .padding(2)
        .background(Capsule().fill(Tokens.surface2))
    }

    // MARK: Dates

    private var quickDates: [(String, Date)] {
        let cal = Calendar.current
        return [
            ("Today", .now),
            ("Tomorrow", cal.date(byAdding: .day, value: 1, to: .now)!),
            ("In 3 workdays", Self.businessDays(3)),
            ("Next week", cal.date(byAdding: .day, value: 7, to: .now)!),
        ]
    }

    /// Keep the chosen time of day, change the day.
    private func setDay(_ day: Date) {
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: draft.due)
        draft.due = cal.date(bySettingHour: time.hour ?? 8, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    static func at8(_ day: Date) -> Date {
        Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
    }

    /// N working days from today (skipping weekends) at 08:00, HubSpot's default.
    static func businessDays(_ n: Int) -> Date {
        let cal = Calendar.current
        var day = Date.now
        var added = 0
        while added < n {
            day = cal.date(byAdding: .day, value: 1, to: day)!
            if !cal.isDateInWeekend(day) { added += 1 }
        }
        return at8(day)
    }
}
