import Foundation
import Testing
@testable import Orbit

/// The pure logic behind the Health add-ons: days, reminders, breathing timing, totals and streaks.
@Suite("Health add-ons")
struct AddOnsHealthTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Days

    @Test func dayKeysAndLastDays() {
        #expect(HealthDay.key(date(2026, 3, 5, 23, 59), calendar: calendar) == "2026-03-05")
        let keys = HealthDay.lastKeys(3, from: date(2026, 3, 1), calendar: calendar)
        #expect(keys == ["2026-02-27", "2026-02-28", "2026-03-01"])
        let pruned = HealthDay.prune(["2026-03-01": 1, "2026-02-28": 2, "2026-01-01": 3], keep: 2,
                                     now: date(2026, 3, 1), calendar: calendar)
        #expect(pruned == ["2026-03-01": 1, "2026-02-28": 2])
    }

    @Test func durations() {
        #expect(HealthDuration.short(42) == "42s")
        #expect(HealthDuration.short(12 * 60 + 5) == "12m")
        #expect(HealthDuration.short(2 * 3600 + 5 * 60) == "2h 05m")
    }

    // MARK: Water

    @Test func waterCountsUndoAndGoal() {
        var log = WaterLog()
        log.add(on: "d"); log.add(on: "d"); log.undo(on: "d")
        #expect(log.count(on: "d") == 1)
        log.undo(on: "d"); log.undo(on: "d")
        #expect(log.count(on: "d") == 0)
        #expect(log.days["d"] == nil)
        log.setGoal(0); #expect(log.goal == 1)
        log.setGoal(99); #expect(log.goal == 20)
        log.setGoal(4); log.add(on: "d"); log.add(on: "d")
        #expect(log.progress(on: "d") == 0.5)
    }

    @Test func waterReminderOnlyInTheDay() {
        let last = date(2026, 3, 5, 10, 0)
        #expect(WaterReminder.isDue(now: date(2026, 3, 5, 11, 0), last: last, everyMinutes: 60, calendar: calendar))
        #expect(!WaterReminder.isDue(now: date(2026, 3, 5, 10, 30), last: last, everyMinutes: 60, calendar: calendar))
        #expect(!WaterReminder.isDue(now: date(2026, 3, 5, 18, 30), last: last, everyMinutes: 60, calendar: calendar))
        #expect(!WaterReminder.isDue(now: date(2026, 3, 6, 8, 0), last: last, everyMinutes: 60, calendar: calendar))
    }

    // MARK: Breaks

    @Test func breaksTakeTurnsAndRespectPauseSnoozeAndIdle() {
        #expect(BreakKind.forBreak(0) == .eyes)
        #expect(BreakKind.forBreak(1) == .posture)
        let last = Date(timeIntervalSince1970: 0)
        let now = last.addingTimeInterval(20 * 60)
        #expect(BreakSchedule.isDue(now: now, last: last, everyMinutes: 20, paused: false, snoozedUntil: nil, idleSeconds: 5))
        #expect(!BreakSchedule.isDue(now: now, last: last, everyMinutes: 25, paused: false, snoozedUntil: nil, idleSeconds: 5))
        #expect(!BreakSchedule.isDue(now: now, last: last, everyMinutes: 20, paused: true, snoozedUntil: nil, idleSeconds: 5))
        #expect(!BreakSchedule.isDue(now: now, last: last, everyMinutes: 20, paused: false, snoozedUntil: now.addingTimeInterval(60), idleSeconds: 5))
        #expect(!BreakSchedule.isDue(now: now, last: last, everyMinutes: 20, paused: false, snoozedUntil: nil, idleSeconds: 300))
        let snooze = now.addingTimeInterval(600)
        #expect(BreakSchedule.next(last: last, everyMinutes: 20, snoozedUntil: snooze) == snooze)
        var log = BreaksLog()
        log.setEvery(5); #expect(log.every == 15)
        log.setEvery(90); #expect(log.every == 60)
    }

    // MARK: Breathing

    @Test func boxBreathingPhases() {
        #expect(BreathPattern.box.cycle == 16)
        let start = BreathGuide.moment(.box, elapsed: 0)
        #expect(start.phase.label == "Breathe in")
        #expect(start.scale == BreathGuide.small)
        #expect(start.secondsLeft == 4)
        #expect(BreathGuide.moment(.box, elapsed: 4.5).phase.label == "Hold")
        #expect(BreathGuide.moment(.box, elapsed: 4.5).scale == 1)
        #expect(BreathGuide.moment(.box, elapsed: 9).phase.label == "Breathe out")
        #expect(BreathGuide.moment(.box, elapsed: 13).index == 3)
        #expect(BreathGuide.moment(.box, elapsed: 13).scale == BreathGuide.small)
        #expect(BreathGuide.moment(.box, elapsed: 16).index == 0) // next round
        let mid = BreathGuide.moment(.box, elapsed: 2)
        #expect(abs(mid.scale - 0.75) < 0.001)
    }

    @Test func relaxBreathingPhases() {
        #expect(BreathPattern.relax.cycle == 19)
        #expect(BreathGuide.moment(.relax, elapsed: 5).phase.label == "Hold")
        #expect(BreathGuide.moment(.relax, elapsed: 5).secondsLeft == 6)
        #expect(BreathGuide.moment(.relax, elapsed: 11).phase.label == "Breathe out")
        #expect(BreathGuide.moment(.relax, elapsed: 18.9).index == 2)
        #expect(BreathGuide.moment(.relax, elapsed: 19).index == 0)
    }

    // MARK: Screen time

    @Test func screenTimeTotalsTopAndPrune() {
        var log = ScreenTimeLog()
        let now = date(2026, 3, 10)
        let today = HealthDay.key(now, calendar: calendar)
        log.add(60, app: "a", name: "Alpha", on: today)
        log.add(30, app: "b", name: "Beta", on: today)
        log.add(90, app: "b", name: "Beta", on: today)
        log.add(500, app: "old", name: "Old", on: "2026-02-01")
        #expect(log.total(on: today) == 180)
        #expect(log.top(on: today).map(\.app) == ["b", "a"])
        #expect(log.top(on: today, limit: 1).first?.seconds == 120)
        log.prune(now: now, calendar: calendar)
        #expect(log.days.keys.sorted() == [today])
        #expect(log.names["old"] == nil)
        #expect(log.name("a") == "Alpha")
    }

    // MARK: Mood

    @Test func moodRecordClampsAndStreaks() {
        var log = MoodLog()
        let now = date(2026, 3, 10, 15)
        log.record(MoodEntry(mood: 9, energy: 0, note: "  fine  "), on: "2026-03-10")
        #expect(log.days["2026-03-10"] == MoodEntry(mood: 5, energy: 1, note: "fine"))
        log.record(MoodEntry(mood: 3, energy: 3), on: "2026-03-09")
        log.record(MoodEntry(mood: 3, energy: 3), on: "2026-03-07")
        #expect(log.streak(now: now, calendar: calendar) == 2)
        // Not checked in yet today: the streak still counts up to yesterday.
        log.days["2026-03-10"] = nil
        #expect(log.streak(now: now, calendar: calendar) == 1)
        #expect(MoodLog.face(1) == "😞")
        #expect(MoodLog.word(5) == "Great")
    }

    @Test func moodNudgeInTheAfternoonOnly() {
        #expect(!MoodNudge.isDue(now: date(2026, 3, 10, 11), checkedIn: false, calendar: calendar))
        #expect(MoodNudge.isDue(now: date(2026, 3, 10, 15), checkedIn: false, calendar: calendar))
        #expect(!MoodNudge.isDue(now: date(2026, 3, 10, 15), checkedIn: true, calendar: calendar))
    }

    // MARK: Catalog

    @Test @MainActor func catalogHasTheFiveHealthAddOns() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let modules = HealthAddOns.make(ctx).compactMap { $0 as? any AddOnModule }
        #expect(modules.map(\.id) == ["addon.water", "addon.breaks", "addon.breathe", "addon.screentime", "addon.mood"])
        #expect(modules.allSatisfy { $0.addOn.category == .health })
        #expect(modules.first { $0.id == "addon.screentime" }?.addOn.tier == .pro)
        #expect(modules.filter { $0.addOn.tier == .free }.count == 4)
    }

    // MARK: Orbit's moods

    @Test func orbitBreathesAlong() {
        #expect(BreathGuide.orbitMood(.breatheIn) == .wide)
        #expect(BreathGuide.orbitMood(.breatheOut) == .closed)
        #expect(BreathGuide.orbitMood(.holdOut) == .closed)
        #expect(BreathGuide.orbitMotion(.holdOut) == .sleep)
        #expect(abs(BreathGuide.orbitScale(0.5) - 0.62) < 0.0001)
        #expect(abs(BreathGuide.orbitScale(1) - 1) < 0.0001)
        #expect(BreathGuide.orbitScale(0.2) == BreathGuide.orbitScale(0.5))
    }

    @Test func orbitCheersUpWithWater() {
        #expect(WaterOrbit.mood(progress: 0) == .squint)
        #expect(WaterOrbit.mood(progress: 0.3) == .normal)
        #expect(WaterOrbit.mood(progress: 0.8) == .wink)
        #expect(WaterOrbit.mood(progress: 1.2) == .happy)
        #expect(WaterOrbit.motion(progress: 1) == .glow)
        #expect(WaterOrbit.motion(progress: 0.9) == .idle)
    }

    @Test func orbitTiresWithScreenTime() {
        #expect(ScreenTimeOrbit.mood(hours: 1) == .happy)
        #expect(ScreenTimeOrbit.mood(hours: 3) == .normal)
        #expect(ScreenTimeOrbit.mood(hours: 6) == .squint)
        #expect(ScreenTimeOrbit.mood(hours: 9) == .closed)
        #expect(ScreenTimeOrbit.motion(hours: 9) == .sleep)
    }

    @Test func orbitMirrorsMood() {
        #expect(MoodOrbit.mood(nil) == .wide)
        #expect(MoodOrbit.mood(1) == .closed)
        #expect(MoodOrbit.mood(3) == .normal)
        #expect(MoodOrbit.mood(5) == .happy)
        #expect(MoodOrbit.motion(5) == .celebrate)
        #expect(MoodOrbit.gaze(1) != nil && MoodOrbit.gaze(4) == nil)
    }
}
