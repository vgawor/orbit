import Foundation

/// One to-do, from any source (this Mac now, HubSpot in phase 5).
struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var done = false
    var due: Date?
    /// False when only a day was given ("tomorrow"), so we show the day, not 12:00.
    var dueHasTime = false
    var created = Date.now
    var completedAt: Date?
    /// Which provider owns it, e.g. "local" or "hubspot".
    var source = "local"
    /// The project it belongs to (HubSpot project tasks).
    var project: String?
    /// Where to open it, e.g. the task in HubSpot.
    var link: URL?
    /// Extra details shown when you click a task (HubSpot fills these in).
    var start: Date?
    /// HubSpot status: NOT_STARTED, IN_PROGRESS, WAITING, DEFERRED, COMPLETED.
    var status: String?
    /// NONE, LOW, MEDIUM, HIGH
    var priority: String?
    /// TODO, CALL, EMAIL, …
    var type: String?
    var notes: String?

    var isOverdue: Bool {
        guard let due, !done else { return false }
        return dueHasTime ? due < .now : due < Calendar.current.startOfDay(for: .now)
    }

    var isDueToday: Bool { due.map(Calendar.current.isDateInToday) ?? false }
}

/// Somewhere tasks live. Add a provider (e.g. HubSpot) and the Tasks module shows its tasks too.
@MainActor
protocol TaskProvider: AnyObject {
    var sourceID: String { get }
    var displayName: String { get }
    func fetch() async throws -> [TaskItem]
    func add(_ item: TaskItem) async throws -> TaskItem
    func update(_ item: TaskItem) async throws
    func delete(id: String) async throws
}

/// Tasks stored on this Mac in ~/Library/Application Support/Orbit/tasks.json.
@MainActor
final class LocalTaskProvider: TaskProvider {
    let sourceID = "local"
    let displayName = "On this Mac"
    private var items: [TaskItem]

    init() {
        items = Storage.load([TaskItem].self, from: "tasks") ?? []
    }

    func fetch() async throws -> [TaskItem] { items }

    func add(_ item: TaskItem) async throws -> TaskItem {
        var item = item
        item.source = sourceID
        items.append(item)
        save()
        return item
    }

    func update(_ item: TaskItem) async throws {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    func delete(id: String) async throws {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() { Storage.save(items, to: "tasks") }
}

/// Pulls a due date out of what you type: "Send offer tomorrow at 14:00" → title + date.
enum TaskParser {
    static func parse(_ text: String) -> (title: String, due: Date?, hasTime: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).last,
              let date = match.date, let range = Range(match.range, in: trimmed)
        else { return (trimmed, nil, false) }

        let phrase = String(trimmed[range]).lowercased()
        let hasTime = phrase.contains(where: \.isNumber) || phrase.contains("noon") || phrase.contains("midnight")
        var title = trimmed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
        for word in [" at", " by", " on", " due"] where title.lowercased().hasSuffix(word) {
            title = String(title.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
        }
        if title.isEmpty { return (trimmed, nil, false) }
        let due = hasTime ? date : Calendar.current.startOfDay(for: date)
        return (title, due, hasTime)
    }
}
