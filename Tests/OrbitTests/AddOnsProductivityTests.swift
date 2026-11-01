import Foundation
import Testing
@testable import Orbit

/// Productivity add-ons: clipboard, snippets, world clock, day timeline, countdowns.
/// Modules are made with `storageKey: nil` so nothing is read from or written to your real data.
@Suite("Productivity add-ons") @MainActor
struct AddOnsProductivityTests {
    private func ctx() -> AddOnContext { AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {}) }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func catalogHasFiveProductivityAddOns() {
        let modules = ProductivityAddOns.make(ctx()).compactMap { $0 as? any AddOnModule }
        #expect(modules.map(\.id) == ["addon.clipboard", "addon.snippets", "addon.worldclock", "addon.daytimeline", "addon.countdowns"])
        #expect(modules.allSatisfy { $0.addOn.category == .productivity })
        #expect(modules.first { $0.id == "addon.daytimeline" }?.addOn.tier == .pro)
        #expect(modules.filter { $0.addOn.tier == .free }.count == 4)
    }

    // MARK: Clipboard

    @Test func clipboardSkipsPasswords() {
        #expect(ClipboardAddOn.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(ClipboardAddOn.shouldSkip(types: ["org.nspasteboard.TransientType"]))
        #expect(ClipboardAddOn.shouldSkip(types: ["com.agilebits.onepassword"]))
        #expect(!ClipboardAddOn.shouldSkip(types: ["public.utf8-plain-text"]))
    }

    @Test func clipboardKeepsThirtyAndMovesRepeatsUp() {
        var items: [ClipboardAddOn.Item] = []
        for i in 0..<35 { items = ClipboardAddOn.inserting("item \(i)", into: items) }
        #expect(items.count == 30)
        #expect(items.first?.text == "item 34")
        #expect(!items.contains { $0.text == "item 4" })

        // Pinned items don't count towards the limit and never fall off.
        items[29].pinned = true          // "item 5"
        items = ClipboardAddOn.inserting("new", into: items)
        #expect(items.count == 31)
        #expect(items.contains { $0.text == "item 5" && $0.pinned })

        // Copying something again moves it to the top instead of adding a second one, and keeps its pin.
        items = ClipboardAddOn.inserting("item 5", into: items)
        #expect(items.first?.text == "item 5")
        #expect(items.first?.pinned == true)
        #expect(items.filter { $0.text == "item 5" }.count == 1)

        // Blank text is ignored.
        #expect(ClipboardAddOn.inserting("  \n ", into: items) == items)
    }

    @Test func clipboardSearchAndPreview() {
        let items = [ClipboardAddOn.Item(text: "Hello Världen", copied: 2),
                     ClipboardAddOn.Item(text: "other", copied: 1, pinned: true)]
        #expect(ClipboardAddOn.filtered(items, query: "varld").map(\.text) == ["Hello Världen"])
        #expect(ClipboardAddOn.filtered(items, query: "").map(\.text) == ["other", "Hello Världen"])   // pinned first
        #expect(ClipboardAddOn.preview("a\n\n  b\tc") == "a b c")
        #expect(ClipboardAddOn.preview(String(repeating: "x", count: 200), max: 10) == "xxxxxxxxxx…")
    }

    @Test func clipboardPinRemoveAndClear() throws {
        let clip = ClipboardAddOn(ctx(), storageKey: nil)
        clip.record("one"); clip.record("two"); clip.record("three")
        #expect(clip.latest?.text == "three")
        let one = try #require(clip.items.first { $0.text == "one" })
        clip.togglePin(one)
        clip.clearUnpinned()
        #expect(clip.items.map(\.text) == ["one"])
        clip.remove(clip.items[0])
        #expect(clip.items.isEmpty)
    }

    // MARK: Snippets

    @Test func snippetsAddEditDelete() throws {
        let s = SnippetsAddOn(ctx(), storageKey: nil)
        s.newSnippet()
        s.draft?.body = "   "
        s.saveDraft()
        #expect(s.snippets.isEmpty)             // empty text isn't saved
        s.draft?.body = "Best regards,\nSam"
        s.saveDraft()
        #expect(s.snippets.count == 1)
        #expect(s.snippets[0].title == "Best regards, Sam")   // title from the first words
        #expect(s.draft == nil)

        let first = s.snippets[0]
        s.edit(first)
        s.draft?.title = "Sign-off"
        s.saveDraft()
        #expect(s.snippets.count == 1)
        #expect(s.snippets[0].title == "Sign-off")
        #expect(s.snippets[0].id == first.id)

        s.query = "regards"
        #expect(s.visible.count == 1)
        s.query = "nope"
        #expect(s.visible.isEmpty)

        s.delete(first.id)
        #expect(s.snippets.isEmpty)
    }

    @Test func snippetTitles() {
        #expect(SnippetsAddOn.title("  Hi  ", body: "x") == "Hi")
        #expect(SnippetsAddOn.title("", body: "one two three four five six") == "one two three four five")
        #expect(SnippetsAddOn.title("", body: "") == "Untitled")
    }

    // MARK: World clock

    @Test func worldClockNames() {
        #expect(WorldClockMath.cityName("America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(WorldClockMath.cityName("Europe/Stockholm") == "Stockholm")
        #expect(WorldClockMath.cityName("UTC") == "UTC")
        #expect(WorldClockMath.region("America/New_York") == "America")
        #expect(WorldClockMath.region("UTC") == "")
    }

    @Test func worldClockOffsets() {
        #expect(WorldClockMath.offsetLabel(seconds: 0) == "Same time")
        #expect(WorldClockMath.offsetLabel(seconds: 3600) == "+1 h")
        #expect(WorldClockMath.offsetLabel(seconds: -9 * 3600) == "−9 h")
        #expect(WorldClockMath.offsetLabel(seconds: 5 * 3600 + 1800) == "+5 h 30 m")
        #expect(WorldClockMath.offsetLabel(seconds: -1800) == "−30 m")

        // Fixed zones and a fixed moment, so daylight saving doesn't matter.
        let at = date("2026-01-15T12:00:00Z")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!, stockholm = TimeZone(identifier: "Europe/Stockholm")!
        #expect(WorldClockMath.offsetLabel(tokyo, from: stockholm, at: at) == "+8 h")
        #expect(WorldClockMath.hour(at, in: tokyo) == 21)
        #expect(WorldClockMath.dayDifference(tokyo, from: stockholm, at: date("2026-01-15T20:00:00Z")) == "Tomorrow")
        #expect(WorldClockMath.dayDifference(TimeZone(identifier: "America/Los_Angeles")!, from: stockholm,
                                             at: date("2026-01-15T03:00:00Z")) == "Yesterday")
        #expect(WorldClockMath.dayDifference(stockholm, from: stockholm, at: at) == nil)
    }

    @Test func worldClockHints() {
        #expect(WorldClockMath.workHint(hour: 10, weekday: 3) == .working)
        #expect(WorldClockMath.workHint(hour: 8, weekday: 3) == .early)
        #expect(WorldClockMath.workHint(hour: 18, weekday: 3) == .evening)
        #expect(WorldClockMath.workHint(hour: 2, weekday: 3) == .night)
        #expect(WorldClockMath.workHint(hour: 10, weekday: 1) == .weekend)
        #expect(WorldClockMath.isDaytime(12))
        #expect(!WorldClockMath.isDaytime(23))
    }

    @Test func worldClockSearch() {
        let ids = ["Europe/Stockholm", "America/New_York", "America/Argentina/Buenos_Aires", "Etc/GMT+1", "UTC", "Pacific/Port_Moresby"]
        #expect(WorldClockMath.search("stock", in: ids) == ["Europe/Stockholm"])
        #expect(WorldClockMath.search("new york", in: ids) == ["America/New_York"])
        #expect(WorldClockMath.search("america", in: ids) == ["America/New_York", "America/Argentina/Buenos_Aires"])
        #expect(WorldClockMath.search("", in: ids).count == 4)   // no Etc/ or bare UTC
        #expect(WorldClockMath.search("stock", in: ids, exclude: ["Europe/Stockholm"]).isEmpty)
        #expect(!WorldClockMath.search("Tokyo").isEmpty)        // the real list
    }

    @Test func worldClockAddAndRemove() {
        let w = WorldClockAddOn(ctx(), storageKey: nil)
        w.add("Asia/Tokyo")
        w.add("Asia/Tokyo")
        w.add("Not/AZone")
        #expect(w.zones == ["Asia/Tokyo"])
        w.remove("Asia/Tokyo")
        #expect(w.zones.isEmpty)
    }

    // MARK: Day timeline

    @Test func dayTimelineGapsAndWindow() {
        let day = date("2026-03-10T00:00:00Z")
        func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
        let events: [DayTimelineMath.Event] = [
            .init(id: "a", title: "A", start: at(9), end: at(10)),
            .init(id: "b", title: "B", start: at(9.5), end: at(11)),     // overlaps A
            .init(id: "c", title: "C", start: at(11.1), end: at(12)),    // leaves a 6-minute gap: too short
            .init(id: "d", title: "D", start: at(14), end: at(15)),
        ]
        let gaps = DayTimelineMath.freeGaps(events: events, from: at(8), to: at(18))
        #expect(gaps.map { $0.start } == [at(8), at(12), at(15)])
        #expect(gaps.map { $0.end } == [at(9), at(14), at(18)])

        let w = DayTimelineMath.window(events: events, day: day, calendar: utc)
        #expect(w.start == at(8) && w.end == at(18))
        let late = events + [.init(id: "e", title: "E", start: at(7.5), end: at(19.25))]
        let w2 = DayTimelineMath.window(events: late, day: day, calendar: utc)
        #expect(w2.start == at(7) && w2.end == at(20))

        #expect(DayTimelineMath.fraction(at(13), start: at(8), end: at(18)) == 0.5)
        #expect(DayTimelineMath.fraction(at(6), start: at(8), end: at(18)) == 0)

        let cols = DayTimelineMath.columns(events)
        #expect(cols["a"]?.column == 0 && cols["a"]?.of == 2)
        #expect(cols["b"]?.column == 1 && cols["b"]?.of == 2)
        #expect(cols["c"]?.column == 0 && cols["c"]?.of == 1)
        #expect(cols["d"]?.of == 1)
    }

    // MARK: Countdowns

    @Test func countdownWording() {
        let now = date("2026-03-10T10:00:00Z")
        #expect(CountdownMath.remaining(date("2026-03-22T09:00:00Z"), now: now, calendar: utc) == ("12", "days left"))
        #expect(CountdownMath.remaining(date("2026-03-11T20:00:00Z"), now: now, calendar: utc) == ("1", "day left"))
        #expect(CountdownMath.remaining(date("2026-03-11T08:00:00Z"), now: now, calendar: utc) == ("22h", "left"))
        #expect(CountdownMath.remaining(date("2026-03-10T14:30:00Z"), now: now, calendar: utc) == ("4h 30m", "left"))
        #expect(CountdownMath.remaining(date("2026-03-09T14:30:00Z"), now: now, calendar: utc) == ("Done", ""))
        #expect(CountdownMath.isDueToday(date("2026-03-10T23:00:00Z"), now: now, calendar: utc))
        #expect(!CountdownMath.isDueToday(date("2026-03-11T01:00:00Z"), now: now, calendar: utc))
    }

    @Test func countdownProgressAndOrder() {
        let created = date("2026-03-01T00:00:00Z"), target = date("2026-03-11T00:00:00Z")
        #expect(CountdownMath.progress(created: created, target: target, now: date("2026-03-06T00:00:00Z")) == 0.5)
        #expect(CountdownMath.progress(created: created, target: target, now: date("2026-04-01T00:00:00Z")) == 1)
        #expect(CountdownMath.progress(created: created, target: target, now: date("2026-02-01T00:00:00Z")) == 0)

        let now = date("2026-03-10T10:00:00Z")
        func c(_ t: String, _ d: String) -> CountdownsAddOn.Countdown {
            .init(title: t, target: date(d).timeIntervalSince1970, created: created.timeIntervalSince1970)
        }
        let list = [c("Later", "2026-05-01T00:00:00Z"), c("Old", "2026-01-01T00:00:00Z"),
                    c("Earlier today", "2026-03-10T08:00:00Z"), c("Soon", "2026-03-12T00:00:00Z")]
        #expect(CountdownMath.nearest(list, now: now, calendar: utc)?.title == "Earlier today")
        #expect(CountdownMath.sorted(list, now: now).map(\.title) == ["Soon", "Later", "Earlier today", "Old"])
    }

    @Test func countdownAttentionAndAlert() {
        let alerts = AlertCenter()
        let cd = CountdownsAddOn(AddOnContext(alerts: alerts, openPanel: { _ in }, closePanel: {}), storageKey: nil)
        #expect(cd.attention == nil)
        cd.add(title: "  ", target: .now.addingTimeInterval(3600))
        #expect(cd.countdowns.isEmpty)
        let soon = Calendar.current.isDate(.now.addingTimeInterval(60), inSameDayAs: .now)
        cd.add(title: "Launch day", target: .now.addingTimeInterval(60))
        cd.tick()
        if soon { #expect(cd.attention?.headline == "Launch day is today") }
        #expect(alerts.current == nil)
        cd.tick(at: .now.addingTimeInterval(120))
        #expect(alerts.current?.title == "Launch day is here")
        #expect(cd.countdowns[0].notified)
        cd.remove(cd.countdowns[0].id)
        #expect(cd.countdowns.isEmpty)
    }

    // MARK: Orbit's moods

    @Test func countdownOrbitGetsExcitedAsTheDayComes() {
        let now = date("2026-03-10T10:00:00Z")
        func look(_ s: String) -> ProductivityOrbit { CountdownMath.orbit(date(s), now: now, calendar: utc) }
        #expect(look("2026-08-01T00:00:00Z") == .asleep)                    // months away: dozing
        #expect(look("2026-04-01T00:00:00Z") == .calm)                      // weeks away
        #expect(look("2026-03-15T00:00:00Z").hop == 3)                      // 5 days: hopping
        #expect(look("2026-03-12T00:00:00Z").hop == 6)                      // 2 days: hopping more
        #expect(look("2026-03-11T09:00:00Z").motion == .nudge)              // tomorrow: bouncing
        #expect(look("2026-03-10T20:00:00Z").motion == .celebrate)          // today
        #expect(look("2026-03-10T08:00:00Z").motion == .celebrate)          // done earlier today
        #expect(look("2026-03-01T08:00:00Z") == ProductivityOrbit(mood: .happy, motion: .still))
    }

    @Test func worldClockOrbitSleepsAtNight() {
        #expect(WorldClockMath.orbit(.night) == .asleep)
        #expect(WorldClockMath.orbit(.working).motion == .working)
        #expect(WorldClockMath.orbit(.early).mood == .squint)
        #expect(WorldClockMath.orbit(.evening) == .happy)
        #expect(WorldClockMath.orbit(WorldClockMath.workHint(hour: 3, weekday: 3)) == .asleep)
    }

    @Test func dayTimelineOrbitFollowsYourDay() {
        let day = date("2026-03-10T00:00:00Z")
        func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
        let events: [DayTimelineMath.Event] = [
            .init(id: "a", title: "A", start: at(9), end: at(10)),
            .init(id: "b", title: "B", start: at(14), end: at(15)),
        ]
        #expect(DayTimelineMath.orbit(events: events, now: at(9.5)).motion == .working)
        #expect(DayTimelineMath.orbit(events: events, now: at(13.9)).motion == .nudge)
        #expect(DayTimelineMath.orbit(events: events, now: at(12)) == .happy)
        #expect(DayTimelineMath.orbit(events: events, now: at(16)).motion == .glow)
        #expect(DayTimelineMath.orbit(events: [], now: at(12)) == .happy)
    }

    @Test func snippetsOrbitAndHomeCard() {
        #expect(SnippetsAddOn.orbit(editing: false, copied: false) == .calm)
        #expect(SnippetsAddOn.orbit(editing: true, copied: false).motion == .working)
        #expect(SnippetsAddOn.orbit(editing: true, copied: true).motion == .celebrate)
        let s = SnippetsAddOn(ctx(), storageKey: nil)
        #expect(s.homeCard == nil)
        s.newSnippet()
        s.draft?.body = "Best regards"
        s.saveDraft()
        #expect(s.homeCard != nil)
    }
}
