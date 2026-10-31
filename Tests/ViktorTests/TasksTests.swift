import Foundation
import Testing
@testable import Viktor

/// A task source kept in memory, so tests never touch the real task file or HubSpot.
@MainActor
final class FakeProvider: TaskProvider {
    let sourceID: String
    let displayName: String
    var items: [TaskItem]
    var failUpdates = false
    var updates: [TaskItem] = []
    struct Failure: LocalizedError { var errorDescription: String? { "offline" } }

    init(_ source: String = "local", _ items: [TaskItem] = []) {
        sourceID = source; displayName = source; self.items = items
    }
    func fetch() async throws -> [TaskItem] { items }
    func add(_ item: TaskItem) async throws -> TaskItem { items.append(item); return item }
    func update(_ item: TaskItem) async throws {
        if failUpdates { throw Failure() }
        updates.append(item)
    }
    func delete(id: String) async throws { items.removeAll { $0.id == id } }
}

@Suite("Tasks") @MainActor
struct TasksTests {
    let cal = Calendar.current
    var yesterday: Date { cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))! }
    var nextWeek: Date { cal.date(byAdding: .day, value: 7, to: .now)! }

    @Test func groupsIntoTodayUpcomingSomeday() async {
        let p = FakeProvider("local", [
            TaskItem(id: "late", title: "Late", due: yesterday),
            TaskItem(id: "today", title: "Today", due: cal.startOfDay(for: .now)),
            TaskItem(id: "later", title: "Later", due: nextWeek),
            TaskItem(id: "some", title: "Someday"),
            TaskItem(id: "old", title: "Done last week", done: true, due: yesterday,
                     completedAt: cal.date(byAdding: .day, value: -6, to: .now)),
        ])
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        await tasks.reload()
        #expect(tasks.today.map(\.id) == ["late", "today"])
        #expect(tasks.upcoming.map(\.id) == ["later"])
        #expect(tasks.someday.map(\.id) == ["some"])   // done last week → gone
        #expect(tasks.todayLeft == 2)
        #expect(tasks.peekChip?.text == "1 overdue")
    }

    @Test func tickedTaskStaysForTheDayAtTheBottom() async throws {
        let p = FakeProvider("local", [
            TaskItem(id: "a", title: "A", due: cal.startOfDay(for: .now)),
            TaskItem(id: "b", title: "B", due: cal.startOfDay(for: .now).addingTimeInterval(60)),
        ])
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        await tasks.reload()
        tasks.toggle(try #require(tasks.items.first { $0.id == "a" }))
        #expect(tasks.today.map(\.id) == ["b", "a"])   // still visible, sunk to the bottom
        #expect(tasks.today.last?.done == true)
        #expect(tasks.todayLeft == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.updates.first?.id == "a")            // saved to its source
    }

    @Test func failedSaveIsUndone() async throws {
        let p = FakeProvider("hubspot", [TaskItem(id: "h", title: "Call", source: "hubspot")])
        p.failUpdates = true
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        await tasks.reload()
        tasks.toggle(tasks.items[0])
        #expect(tasks.items[0].done)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!tasks.items[0].done)
        #expect(tasks.lastError == "offline")
    }

    @Test func quickAddParsesTheDate() async throws {
        let p = FakeProvider()
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        tasks.add("Send offer tomorrow at 9:00")
        #expect(tasks.items.first?.title == "Send offer")
        #expect(tasks.upcoming.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.items.count == 1)
    }

    @Test func statusDoneMarksTaskDone() async throws {
        let p = FakeProvider("hubspot", [TaskItem(id: "h", title: "Call", source: "hubspot", status: "NOT_STARTED")])
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        await tasks.reload()
        tasks.setStatus(tasks.items[0], "COMPLETED")
        #expect(tasks.items[0].done && tasks.items[0].completedAt != nil)
        tasks.setStatus(tasks.items[0], "IN_PROGRESS")
        #expect(!tasks.items[0].done)
    }

    @Test func showOpensTheTasksTab() async {
        var opened: String?
        let tasks = TasksModule(providers: [FakeProvider("local", [TaskItem(id: "x", title: "X")])], openPanel: { opened = $0 })
        await tasks.reload()
        tasks.show(tasks.items[0])
        #expect(opened == "tasks")
        #expect(tasks.selected?.id == "x")
    }

    @Test func onlyLocalTasksCanBeDeleted() async {
        let tasks = TasksModule(providers: [FakeProvider("hubspot", [TaskItem(id: "h", title: "H", source: "hubspot")])], openPanel: { _ in })
        await tasks.reload()
        tasks.delete(tasks.items[0])
        #expect(tasks.items.count == 1)
    }

    @Test func readsHubSpotTasks() throws {
        let json: [String: Any] = ["id": "123", "properties": [
            "hs_task_subject": "Follow up offer", "hs_task_status": "NOT_STARTED",
            "hs_timestamp": "2026-10-30T13:00:00.000Z", "hs_task_priority": "HIGH",
            "hs_task_type": "CALL", "hs_body_preview": "  ", "hs_start_date": "2026-10-28T08:00:00Z",
        ]]
        let t = try #require(HubSpotTaskProvider.task(from: json))
        #expect(t.id == "123" && t.title == "Follow up offer" && t.source == "hubspot")
        #expect(!t.done && t.dueHasTime && t.priority == "HIGH" && t.type == "CALL")
        #expect(t.notes == nil)        // blank text is dropped
        #expect(t.start != nil)
        let done = try #require(HubSpotTaskProvider.task(from: ["id": "1", "properties": ["hs_task_status": "COMPLETED"]]))
        #expect(done.done && done.title == "Untitled task" && done.due == nil)
        #expect(HubSpotTaskProvider.task(from: ["properties": [:]]) == nil)
    }

    @Test func newTaskFormBuildsTheTask() {
        let due = Calendar.current.date(byAdding: .day, value: 2, to: .now)!
        let t = LocalTaskForm.makeTask(title: " Call Anna ", due: due, hasTime: false, priority: "HIGH",
                                       link: "example.com/offer", notes: "  Ask about Q4\n")
        #expect(t.title == "Call Anna")
        #expect(t.due == Calendar.current.startOfDay(for: due) && !t.dueHasTime)
        #expect(t.priority == "HIGH")
        #expect(t.link?.absoluteString == "https://example.com/offer")
        #expect(t.notes == "Ask about Q4")
        let bare = LocalTaskForm.makeTask(title: "X", due: nil, hasTime: true, priority: "NONE", link: " ", notes: "")
        #expect(bare.due == nil && !bare.dueHasTime && bare.priority == nil && bare.link == nil && bare.notes == nil)
    }

    @Test func addLocalKeepsAllDetails() async throws {
        let p = FakeProvider()
        let tasks = TasksModule(providers: [p], openPanel: { _ in })
        tasks.addLocal(TaskItem(title: "Offer", link: URL(string: "https://x.se"), priority: "MEDIUM", notes: "n"))
        try await Task.sleep(for: .milliseconds(50))
        let saved = try #require(p.items.first)
        #expect(saved.source == "local" && saved.priority == "MEDIUM" && saved.notes == "n" && saved.link != nil)
        #expect(tasks.someday.count == 1)
    }
}
