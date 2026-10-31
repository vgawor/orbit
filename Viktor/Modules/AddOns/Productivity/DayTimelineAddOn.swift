@preconcurrency import EventKit
import SwiftUI

/// Today's calendar as a vertical timeline, with a "now" line and the free time between meetings.
/// Reads the calendar only when Orbit already has full calendar access (from Meetings); never asks itself.
@MainActor
@Observable
final class DayTimelineAddOn: AddOnModule {
    let id = "addon.daytimeline"
    let title = "Day timeline"
    let symbol = "calendar.day.timeline.left"
    let addOn = AddOnInfo(category: .productivity, tier: .pro,
                          summary: "Today's meetings on a timeline, with your free time picked out.")

    private(set) var events: [DayTimelineMath.Event] = []
    private(set) var hasAccess = false
    private(set) var now = Date.now

    private let ctx: AddOnContext
    private var store: EKEventStore?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            hasAccess = true
            events = Self.sample
        }
    }

    // MARK: Lifecycle

    func start() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    /// Reads today's events. Only when access was already given: this never shows a permission prompt.
    func reload() {
        now = .now
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            hasAccess = false
            events = []
            return
        }
        hasAccess = true
        let store = self.store ?? EKEventStore()
        if self.store == nil {
            self.store = store
            changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map { e in
                DayTimelineMath.Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Busy",
                                      start: e.startDate, end: e.endDate,
                                      color: e.calendar?.cgColor.map { Color(cgColor: $0) } ?? Tokens.zoom)
            }
            .sorted { $0.start < $1.start }
    }

    /// Opens the Meetings tab, where calendar access is turned on.
    func openMeetings() { ctx.openPanel("meetings") }

    // MARK: Derived

    var window: (start: Date, end: Date) { DayTimelineMath.window(events: events, day: now) }
    var gaps: [DayTimelineMath.Gap] { DayTimelineMath.freeGaps(events: events, from: window.start, to: window.end) }
    /// Free gaps still ahead of you (the current one cut to start now).
    var gapsAhead: [DayTimelineMath.Gap] {
        gaps.compactMap { g in
            g.end <= now ? nil : DayTimelineMath.Gap(start: max(g.start, now), end: g.end)
        }.filter { $0.duration >= 10 * 60 }
    }
    var current: DayTimelineMath.Event? { events.first { $0.start <= now && $0.end > now } }
    var next: DayTimelineMath.Event? { events.first { $0.start > now } }
    var orbit: ProductivityOrbit { DayTimelineMath.orbit(events: events, now: now) }

    // MARK: Views

    var panel: AnyView { AnyView(DayTimelinePanel(module: self)) }

    var homeCard: AnyView? {
        guard hasAccess else { return nil }
        return AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        CardLabel("Today")
                        let left = self.events.filter { $0.end > self.now }.count
                        Text(left == 0 ? "No more meetings" : "\(left) meeting\(left == 1 ? "" : "s") left")
                            .font(.system(size: 13, weight: .semibold))
                        if let cur = self.current {
                            Text("In \(cur.title) until \(DayTimelineMath.clock(cur.end))")
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                        if let gap = self.gapsAhead.first {
                            Label("Free \(DayTimelineMath.clock(gap.start))–\(DayTimelineMath.clock(gap.end))", systemImage: "leaf")
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.live)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ProductivityOrbitView(look: self.orbit, size: 40)
                }
            }
        }.buttonStyle(.plain))
    }

    private static var sample: [DayTimelineMath.Event] {
        let day = Calendar.current.startOfDay(for: .now)
        func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
        let purple = Color(red: 0.63, green: 0.59, blue: 0.99), green = Tokens.live, orange = Color(red: 1, green: 0.6, blue: 0.3)
        return [
            .init(id: "1", title: "Standup", start: at(9), end: at(9.25), color: Tokens.zoom),
            .init(id: "2", title: "Design review", start: at(10), end: at(11.5), color: purple),
            .init(id: "3", title: "Lunch with Anna", start: at(12), end: at(13), color: green),
            .init(id: "4", title: "Client call – Northwind", start: at(14), end: at(14.75), color: orange),
            .init(id: "5", title: "1:1 Erik", start: at(14.5), end: at(15.25), color: Tokens.zoom),
            .init(id: "6", title: "Wrap-up", start: at(16.5), end: at(17), color: purple),
        ]
    }
}

/// The sums behind the day timeline. Kept apart so they're easy to test.
enum DayTimelineMath {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        var color: Color = Tokens.zoom
    }

    struct Gap: Equatable, Hashable {
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The part of the day to draw: 8:00–18:00, stretched to whole hours around any earlier or later events.
    static func window(events: [Event], day: Date, calendar: Calendar = .current,
                       defaultStart: Int = 8, defaultEnd: Int = 18) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        var start = calendar.date(bySettingHour: defaultStart, minute: 0, second: 0, of: dayStart)!
        var end = calendar.date(bySettingHour: defaultEnd, minute: 0, second: 0, of: dayStart)!
        if let first = events.map(\.start).min(), first < start {
            start = calendar.dateInterval(of: .hour, for: max(first, dayStart))?.start ?? first
        }
        if let last = events.map(\.end).max(), last > end {
            let clipped = min(last, dayEnd)
            let hour = calendar.dateInterval(of: .hour, for: clipped)
            end = hour.map { $0.start == clipped ? clipped : $0.end } ?? clipped
        }
        return (max(start, dayStart), min(end, dayEnd))
    }

    /// Free stretches between `from` and `to` that no event covers, at least `minimum` long.
    static func freeGaps(events: [Event], from: Date, to: Date, minimum: TimeInterval = 15 * 60) -> [Gap] {
        let busy = events.map { (max($0.start, from), min($0.end, to)) }.filter { $0.0 < $0.1 }.sorted { $0.0 < $1.0 }
        var gaps: [Gap] = []
        var cursor = from
        for (s, e) in busy {
            if s > cursor, s.timeIntervalSince(cursor) >= minimum { gaps.append(Gap(start: cursor, end: s)) }
            cursor = max(cursor, e)
        }
        if to > cursor, to.timeIntervalSince(cursor) >= minimum { gaps.append(Gap(start: cursor, end: to)) }
        return gaps
    }

    /// Where `date` sits in the window, 0 (top) to 1 (bottom).
    static func fraction(_ date: Date, start: Date, end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    /// Side-by-side columns for overlapping events: event id → (column, number of columns in its group).
    static func columns(_ events: [Event]) -> [String: (column: Int, of: Int)] {
        var result: [String: (Int, Int)] = [:]
        var group: [Event] = [], groupEnd = Date.distantPast
        var laneEnds: [Date] = []
        func flush() {
            let count = max(1, laneEnds.count)
            for e in group { result[e.id] = (result[e.id]?.0 ?? 0, count) }
            group = []; laneEnds = []
        }
        for e in events.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if e.start >= groupEnd { flush() }
            let lane = laneEnds.firstIndex { $0 <= e.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(e.end) } else { laneEnds[lane] = e.end }
            result[e.id] = (lane, 1)
            group.append(e)
            groupEnd = max(groupEnd, e.end)
        }
        flush()
        return result.mapValues { (column: $0.0, of: $0.1) }
    }

    static func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    /// Orbit riding the "now" line: hard at work in a meeting, perked up when one starts within
    /// 10 minutes, happy in free time, and glowing contentedly once the day's meetings are done.
    static func orbit(events: [Event], now: Date) -> ProductivityOrbit {
        if events.contains(where: { $0.start <= now && $0.end > now }) {
            return ProductivityOrbit(mood: .squint, motion: .working)
        }
        guard let next = events.filter({ $0.start > now }).min(by: { $0.start < $1.start }) else {
            return events.isEmpty ? .happy : ProductivityOrbit(mood: .happy, motion: .glow, tint: Tokens.live)
        }
        if next.start.timeIntervalSince(now) <= 10 * 60 {
            return ProductivityOrbit(mood: .wide, motion: .nudge, tint: Tokens.attention)
        }
        return .happy
    }
}

// MARK: - Panel

private struct DayTimelinePanel: View {
    let module: DayTimelineAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Today", subtitle: subtitle, tint: ProductivityAddOns.tint)
            if module.hasAccess {
                HStack(alignment: .top, spacing: 12) {
                    DayTimelineChart(module: module)
                        .padding(.vertical, 12).padding(.leading, 10).padding(.trailing, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassCard(24)
                    DayTimelineSummary(module: module).frame(width: 210)
                }
            } else {
                VStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        OrbitView(size: 60, mood: .wide, motion: .idle, gaze: CGVector(dx: 0.8, dy: 0.5))
                        Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 20))
                            .foregroundStyle(Tokens.secondary)
                            .offset(x: 18, y: 2)
                    }
                    Text("Turn on Meetings to show your calendar").font(.system(size: 13, weight: .semibold))
                    Text("Day uses the calendar access you give Meetings. It never asks on its own.")
                        .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                    GlassPillButton(title: "Open Meetings", symbol: "calendar") { module.openMeetings() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(24)
            }
        }
        .onAppear { if !ModuleRegistry.isPreview { module.reload() } }
    }

    private var subtitle: String {
        let date = module.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard module.hasAccess else { return date }
        let n = module.events.count
        return "\(date) · \(n == 0 ? "no meetings" : "\(n) meeting\(n == 1 ? "" : "s")")"
    }
}

private struct DayTimelineChart: View {
    let module: DayTimelineAddOn

    var body: some View {
        let (start, end) = module.window
        let events = module.events
        let gaps = module.gaps
        let columns = DayTimelineMath.columns(events)
        let hours = Int((end.timeIntervalSince(start) / 3600).rounded())
        GeometryReader { geo in
            let labelWidth: CGFloat = 40
            let trackWidth = geo.size.width - labelWidth
            let h = geo.size.height
            let y: (Date) -> CGFloat = { CGFloat(DayTimelineMath.fraction($0, start: start, end: end)) * h }
            ZStack(alignment: .topLeading) {
                // Hour lines and labels.
                ForEach(0...max(hours, 1), id: \.self) { i in
                    let date = start.addingTimeInterval(Double(i) * 3600)
                    let yy = y(date)
                    Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated))))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Tokens.faint)
                        .frame(width: labelWidth - 6, alignment: .trailing)
                        .offset(y: yy - 6)
                        .opacity(hours > 11 && i % 2 == 1 ? 0 : 1)
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: trackWidth, height: 1)
                        .offset(x: labelWidth, y: yy)
                }
                // Free time.
                ForEach(gaps, id: \.self) { g in
                    let top = y(g.start), height = y(g.end) - top
                    let past = g.end <= module.now
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Tokens.live.opacity(past ? 0.04 : 0.1))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Tokens.live.opacity(past ? 0.15 : 0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .overlay(alignment: .topTrailing) {
                            if height >= 18 {
                                Text("Free · \(ProductivityFormat.duration(g.duration))")
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Tokens.live.opacity(past ? 0.4 : 0.9))
                                    .padding(.horizontal, 7).padding(.top, height >= 24 ? 4 : 2)
                            }
                        }
                        .frame(width: trackWidth - 4, height: max(height - 2, 2))
                        .offset(x: labelWidth + 2, y: top + 1)
                }
                // Events.
                ForEach(events) { e in
                    let top = y(e.start), height = max(y(e.end) - top, 6)
                    let col = columns[e.id] ?? (0, 1)
                    let w = (trackWidth - 4) / CGFloat(col.of)
                    DayTimelineBlock(event: e, height: height, past: e.end <= module.now)
                        .frame(width: w - 3, height: max(height - 2, 4))
                        .offset(x: labelWidth + 2 + CGFloat(col.column) * w, y: top + 1)
                }
                // Now line.
                if module.now >= start && module.now <= end {
                    let yy = y(module.now)
                    HStack(spacing: 0) {
                        Text(DayTimelineMath.clock(module.now))
                            .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(Tokens.error))
                            .frame(width: labelWidth, alignment: .trailing)
                        Rectangle().fill(Tokens.error).frame(height: 1.5)
                            .overlay(alignment: .trailing) {
                                // Orbit rides the line, sitting on it near the end.
                                ProductivityOrbitView(look: module.orbit, size: 28)
                                    .offset(x: -10, y: -10)
                                    .help(module.current.map { "Orbit's in \($0.title) with you" } ?? "Orbit's enjoying the free time")
                            }
                    }
                    .frame(width: geo.size.width)
                    .offset(y: yy - 7)
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .topLeading)
        }
    }
}

private struct DayTimelineBlock: View {
    let event: DayTimelineMath.Event
    let height: CGFloat
    let past: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3)
            if height >= 14 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if height >= 30 {
                        Text("\(DayTimelineMath.clock(event.start))–\(DayTimelineMath.clock(event.end))")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tokens.secondary)
                    }
                }
                .padding(.top, height >= 22 ? 3 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 3).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(event.color.opacity(0.24)))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(past ? 0.45 : 1)
        .help("\(event.title) · \(DayTimelineMath.clock(event.start))–\(DayTimelineMath.clock(event.end))")
    }
}

private struct DayTimelineSummary: View {
    let module: DayTimelineAddOn

    var body: some View {
        let ahead = module.gapsAhead
        let freeLeft = ahead.reduce(0) { $0 + $1.duration }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                CardLabel("Now")
                if let cur = module.current {
                    Text(cur.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("Until \(DayTimelineMath.clock(cur.end))").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                } else {
                    Text("Free").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.live)
                    if let next = module.next {
                        Text("Next: \(next.title) at \(DayTimelineMath.clock(next.start))")
                            .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(2)
                    } else {
                        Text("Nothing else today").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(20)

            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Free time left")
                Text(ProductivityFormat.duration(freeLeft)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                if ahead.isEmpty {
                    Text("No free blocks left today.").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                ForEach(ahead.prefix(4), id: \.self) { g in
                    HStack(spacing: 6) {
                        Circle().fill(Tokens.live).frame(width: 5, height: 5)
                        Text("\(DayTimelineMath.clock(g.start))–\(DayTimelineMath.clock(g.end))")
                            .font(.system(size: 11.5).monospacedDigit())
                        Spacer(minLength: 2)
                        Text(ProductivityFormat.duration(g.duration)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Tokens.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(20)
        }
    }
}
