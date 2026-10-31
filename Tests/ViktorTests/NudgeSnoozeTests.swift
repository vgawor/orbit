import Foundation
import Testing
@testable import Viktor

@MainActor
struct NudgeSnoozeTests {
    private func freshDefaults() -> UserDefaults {
        let name = "snooze-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func optionsEndAtTheRightTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 7, minute: 36))!
        #expect(SnoozeOption.hour.until(from: now, calendar: cal) == now.addingTimeInterval(3600))
        let tomorrow = SnoozeOption.tomorrow.until(from: now, calendar: cal)
        #expect(tomorrow == cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 8))!)
        #expect(SnoozeOption.untilChanged.until(from: now) == .distantFuture)
    }

    @Test func snoozeEndsAndIsSaved() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = NudgeSnoozes(defaults: defaults)
        s.snooze("tasks-overdue-a", .hour, now: now)
        s.snooze("meeting-1", .untilChanged, now: now)
        #expect(s.isSnoozed("tasks-overdue-a", now: now.addingTimeInterval(60)))
        #expect(!s.isSnoozed("tasks-overdue-a", now: now.addingTimeInterval(3601)))
        #expect(!s.isSnoozed("tasks-overdue-b", now: now))

        // A restart keeps them.
        let again = NudgeSnoozes(defaults: defaults)
        #expect(again.isSnoozed("meeting-1", now: now.addingTimeInterval(86_400 * 30)))
        again.wake("meeting-1")
        #expect(!again.isSnoozed("meeting-1"))
    }

    @Test func wakeAllClearsEverything() {
        let s = NudgeSnoozes(defaults: freshDefaults())
        s.snooze("a", .tomorrow)
        #expect(s.hasActive())
        s.wakeAll()
        #expect(!s.hasActive())
    }

    @Test func keepsAtMostTheLimit() {
        let s = NudgeSnoozes(defaults: freshDefaults())
        for i in 0..<(NudgeSnoozes.limit + 10) { s.snooze("id-\(i)", .hour) }
        #expect(s.until.count == NudgeSnoozes.limit)
    }
}
