import SwiftUI

/// Create a task on this Mac: title, due date (time optional), priority, a link and notes.
/// Lighter than the HubSpot form. Enter in the title saves right away.
struct LocalTaskForm: View {
    let module: TasksModule
    let initialText: String

    @State private var title = ""
    @State private var hasDue = false
    @State private var due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var hasTime = false
    @State private var priority = "NONE"
    @State private var link = ""
    @State private var notes = ""
    @FocusState private var titleFocused: Bool

    private static let priorities = [("NONE", "None"), ("LOW", "Low"), ("MEDIUM", "Medium"), ("HIGH", "High")]

    var body: some View {
        // Stacked, so it fits beside the task list (design: "Tasks + new task").
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("New task").font(.system(size: 15, weight: .semibold))
                Text("On this Mac").font(.system(size: 11)).foregroundStyle(Tokens.faint)
                Spacer()
                Button { module.composingLocal = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24).glassSurface(Circle(), interactive: true)
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cancel")
            }

            field("Title") {
                TextField("Task title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(inputBackground)
                    .focused($titleFocused)
                    .onSubmit(save)
            }

            field("Due") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        choice("No date", on: !hasDue) { hasDue = false }
                        ForEach(quickDates, id: \.0) { name, date in
                            choice(name, on: hasDue && Calendar.current.isDate(due, inSameDayAs: date)) { setDay(date) }
                        }
                    }
                    if hasDue {
                        HStack(spacing: 8) {
                            DatePicker("", selection: $due, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                                .labelsHidden().datePickerStyle(.stepperField).controlSize(.small).fixedSize()
                            Toggle("Time", isOn: $hasTime)
                                .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
                        }
                    }
                }
            }

            field("Priority") {
                HStack(spacing: 2) {
                    ForEach(Self.priorities, id: \.0) { key, name in
                        Button { priority = key } label: {
                            HStack(spacing: 4) {
                                if key != "NONE" { Circle().fill(TaskRow.priorityColor(key)).frame(width: 6, height: 6) }
                                Text(name)
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .background { if priority == key { Capsule().fill(Color.white.opacity(0.18)) } }
                            .foregroundStyle(priority == key ? .white : Tokens.secondary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.black.opacity(0.25)).overlay(Capsule().stroke(Tokens.stroke)))
            }

            field("Link") {
                TextField("https://… (optional)", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(inputBackground)
            }

            field("Notes") {
                TextField("Anything to remember", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .lineLimit(1...3)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(inputBackground)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                GlassPillButton(title: "Cancel") { module.composingLocal = nil }
                PillButton(title: "Add task", fill: canSave ? .white : Tokens.surface2) { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            // "Call Anna tomorrow 10:00" fills the title and due date.
            let parsed = TaskParser.parse(initialText)
            title = parsed.title
            if let d = parsed.due {
                hasDue = true
                hasTime = parsed.hasTime
                due = parsed.hasTime ? d : (Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
            }
            titleFocused = true
        }
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() {
        guard canSave else { return }
        let item = Self.makeTask(title: title, due: hasDue ? due : nil, hasTime: hasTime,
                                 priority: priority, link: link, notes: notes)
        module.addLocal(item)
        module.composingLocal = nil
    }

    /// Builds the task from the form. A link without a scheme gets https://; blank fields are left out.
    static func makeTask(title: String, due: Date?, hasTime: Bool, priority: String, link: String, notes: String) -> TaskItem {
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var url: URL?
        if !trimmedLink.isEmpty {
            url = URL(string: trimmedLink.contains("://") ? trimmedLink : "https://" + trimmedLink)
        }
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = due.map { hasTime ? $0 : Calendar.current.startOfDay(for: $0) }
        return TaskItem(title: title.trimmingCharacters(in: .whitespaces), due: day, dueHasTime: day != nil && hasTime,
                        link: url, priority: priority == "NONE" ? nil : priority,
                        notes: cleanNotes.isEmpty ? nil : cleanNotes)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            content()
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Tokens.stroke))
    }

    /// A quick choice; the chosen one is a white pill.
    private func choice(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.08)))
                .foregroundStyle(on ? Color.black : .white.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var quickDates: [(String, Date)] {
        let cal = Calendar.current
        return [
            ("Today", .now),
            ("Tomorrow", cal.date(byAdding: .day, value: 1, to: .now)!),
            ("Next week", cal.date(byAdding: .day, value: 7, to: .now)!),
        ]
    }

    /// Keeps the chosen time of day, changes the day.
    private func setDay(_ day: Date) {
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: due)
        due = cal.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
        hasDue = true
    }
}
