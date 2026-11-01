import SwiftUI

/// Named countdowns to dates that matter ("Launch day", "Holiday").
@MainActor
@Observable
final class CountdownsAddOn: AddOnModule {
    let id = "addon.countdowns"
    let title = "Countdowns"
    let symbol = "hourglass"
    let addOn = AddOnInfo(category: .productivity, tier: .free,
                          summary: "Count down to launches, trips and deadlines.")

    struct Countdown: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        /// Seconds since 1970 (stored as numbers so they read back the same way).
        var target: Double
        var created: Double
        /// The "it's here" alert was shown.
        var notified = false
        var targetDate: Date { Date(timeIntervalSince1970: target) }
        var createdDate: Date { Date(timeIntervalSince1970: created) }
    }

    private(set) var countdowns: [Countdown] = []
    private(set) var now = Date.now
    /// The "New countdown" form is open.
    var adding = false

    private let ctx: AddOnContext
    private let storageKey: String?
    private var timer: Timer?

    init(_ ctx: AddOnContext, storageKey: String? = "addon-countdowns") {
        self.ctx = ctx
        self.storageKey = storageKey
        if let storageKey { countdowns = Storage.load([Countdown].self, from: storageKey) ?? [] }
        if ModuleRegistry.isPreview && storageKey != nil { countdowns = Self.sample }
    }

    func start() {
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick(at date: Date = .now) {
        now = date
        var changed = false
        for i in countdowns.indices where !countdowns[i].notified && countdowns[i].targetDate <= date {
            countdowns[i].notified = true
            changed = true
            // Only say so when it just happened, not for something that ended while Orbit was off for days.
            guard date.timeIntervalSince(countdowns[i].targetDate) < 86_400 else { continue }
            ctx.alerts.post(NotchAlert(symbol: "flag.checkered", tint: Tokens.attention,
                                       title: "\(countdowns[i].title) is here",
                                       subtitle: "Your countdown has finished.",
                                       actions: [.init(title: "OK", isPrimary: true)], duration: 6, sound: "Glass"))
        }
        if changed { save() }
    }

    // MARK: Actions

    func add(title: String, target: Date) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        countdowns.append(Countdown(title: name, target: target.timeIntervalSince1970, created: Date.now.timeIntervalSince1970,
                                    notified: target <= .now))
        adding = false
        save()
    }

    func remove(_ id: UUID) {
        countdowns.removeAll { $0.id == id }
        save()
    }

    var sorted: [Countdown] { CountdownMath.sorted(countdowns, now: now) }
    var nearest: Countdown? { CountdownMath.nearest(countdowns, now: now) }

    private func save() {
        guard let storageKey else { return }
        Storage.save(countdowns, to: storageKey)
    }

    // MARK: Module

    var attention: Attention? {
        guard let today = countdowns.filter({ CountdownMath.isDueToday($0.targetDate, now: now) })
            .min(by: { $0.target < $1.target }) else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        return Attention(id: "countdown-\(today.id)-\(day)", symbol: "flag.checkered", tint: Tokens.attention,
                         label: "Today", priority: 1, headline: "\(today.title) is today")
    }

    var peekChip: PeekChip? {
        guard let n = nearest else { return nil }
        let r = CountdownMath.remaining(n.targetDate, now: now)
        return PeekChip(symbol: "hourglass", text: "\(n.title) · \(r.value)\(r.unit.isEmpty ? "" : " " + r.unit.replacingOccurrences(of: " left", with: ""))",
                        tint: Tokens.secondary, priority: 0)
    }

    var panel: AnyView { AnyView(CountdownsPanel(module: self)) }

    var homeCard: AnyView? {
        guard let n = nearest else { return nil }
        return AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        CardLabel("Countdown")
                        Text(n.title).font(.system(size: 12.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        let r = CountdownMath.remaining(n.targetDate, now: self.now)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(r.value).font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text(r.unit).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                        Spacer(minLength: 0)
                        CountdownBar(progress: CountdownMath.progress(created: n.createdDate, target: n.targetDate, now: self.now))
                    }
                    ProductivityOrbitView(look: CountdownMath.orbit(n.targetDate, now: self.now), size: 44)
                }
            }
        }.buttonStyle(.plain))
    }

    private static var sample: [Countdown] {
        let now = Date.now
        func c(_ title: String, inDays d: Double, since s: Double) -> Countdown {
            Countdown(title: title, target: now.addingTimeInterval(d * 86_400).timeIntervalSince1970,
                      created: now.addingTimeInterval(-s * 86_400).timeIntervalSince1970)
        }
        return [c("Launch day", inDays: 12.3, since: 30), c("Summer holiday", inDays: 54, since: 10),
                c("Offer deadline", inDays: 1.6, since: 6), c("Anna's birthday", inDays: 3.5, since: 40)]
    }
}

/// Days-left sums and wording for countdowns. Kept apart so they're easy to test.
enum CountdownMath {
    /// Whole calendar days from today to the target's day (0 = today, negative = passed).
    static func daysLeft(_ target: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
    }

    /// The big value and the words after it: ("12", "days left"), ("Tomorrow", ""), ("4h 30m", "left"), ("Done", "").
    static func remaining(_ target: Date, now: Date, calendar: Calendar = .current) -> (value: String, unit: String) {
        if target <= now { return ("Done", "") }
        let days = daysLeft(target, now: now, calendar: calendar)
        if days >= 2 { return ("\(days)", "days left") }
        if days == 1 {
            // Under a day away but already tomorrow on the calendar: show hours so it doesn't read "1 day".
            let secs = target.timeIntervalSince(now)
            return secs < 86_400 ? (ProductivityFormat.duration(secs), "left") : ("1", "day left")
        }
        return (ProductivityFormat.duration(target.timeIntervalSince(now)), "left")
    }

    /// How much of the wait is behind you, 0 to 1.
    static func progress(created: Date, target: Date, now: Date) -> Double {
        let total = target.timeIntervalSince(created)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(created) / total))
    }

    static func isDueToday(_ target: Date, now: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(target, inSameDayAs: now)
    }

    /// Orbit gets more excited as the day gets close: dozing when it's months away, waiting, hopping in the
    /// last week, bouncing the day before, and celebrating on the day. Calm and happy once it's long done.
    static func orbit(_ target: Date, now: Date, calendar: Calendar = .current) -> ProductivityOrbit {
        if isDueToday(target, now: now, calendar: calendar) { return ProductivityOrbit(mood: .happy, motion: .celebrate) }
        if target <= now { return ProductivityOrbit(mood: .happy, motion: .still) }
        let days = daysLeft(target, now: now, calendar: calendar)
        switch days {
        case ...1: return ProductivityOrbit(mood: .wide, motion: .nudge, tint: Tokens.attention)
        case 2...7: return ProductivityOrbit(mood: .happy, motion: .idle, hop: CGFloat(8 - days))
        case 8...60: return .calm
        default: return .asleep
        }
    }

    /// The next one to come (or one finishing today); nil when all are long done.
    static func nearest(_ list: [CountdownsAddOn.Countdown], now: Date, calendar: Calendar = .current) -> CountdownsAddOn.Countdown? {
        let startOfToday = calendar.startOfDay(for: now)
        return list.filter { $0.targetDate >= startOfToday }.min { $0.target < $1.target }
    }

    /// Upcoming first (soonest on top), then finished ones (most recent first).
    static func sorted(_ list: [CountdownsAddOn.Countdown], now: Date) -> [CountdownsAddOn.Countdown] {
        let upcoming = list.filter { $0.targetDate > now }.sorted { $0.target < $1.target }
        let done = list.filter { $0.targetDate <= now }.sorted { $0.target > $1.target }
        return upcoming + done
    }
}

// MARK: - Views

private struct CountdownBar: View {
    let progress: Double
    var tint: Color = .white
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tint.opacity(0.85)).frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 4)
    }
}

private struct CountdownsPanel: View {
    let module: CountdownsAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AddOnHeader(symbol: module.symbol, title: "Countdowns", subtitle: subtitle, tint: ProductivityAddOns.tint)
                if !module.adding {
                    PillButton(title: "New countdown") { withAnimation(Tokens.spring) { module.adding = true } }
                }
            }
            if module.adding {
                CountdownForm(module: module).transition(.move(edge: .top).combined(with: .opacity))
            }
            if module.countdowns.isEmpty && !module.adding {
                VStack(spacing: 8) {
                    OrbitView(size: 60, mood: .normal, motion: .idle, gaze: CGVector(dx: 0.7, dy: -0.4))
                    Text("Nothing to count down to").font(.system(size: 13, weight: .semibold))
                    Text("Add a launch, a trip or a deadline.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(24)
            } else {
                grid
            }
        }
        .animation(Tokens.spring, value: module.adding)
    }

    private var subtitle: String {
        guard let n = module.nearest else { return "Days left to what matters" }
        let r = CountdownMath.remaining(n.targetDate, now: module.now)
        return "Next: \(n.title) · \(r.value) \(r.unit)".trimmingCharacters(in: .whitespaces)
    }

    private var grid: some View {
        let list = module.sorted
        return NotchScroll {
            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: list.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 10) {
                        CountdownTile(countdown: list[start], module: module)
                        if start + 1 < list.count {
                            CountdownTile(countdown: list[start + 1], module: module)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CountdownTile: View {
    let countdown: CountdownsAddOn.Countdown
    let module: CountdownsAddOn
    @State private var hovering = false

    var body: some View {
        let now = module.now
        let r = CountdownMath.remaining(countdown.targetDate, now: now)
        let today = CountdownMath.isDueToday(countdown.targetDate, now: now)
        let done = countdown.targetDate <= now
        let tint: Color = done ? Tokens.live : today ? Tokens.attention : .white
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(countdown.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if today && !done {
                    Text("Today").font(.system(size: 10, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(Tokens.attention))
                }
                Spacer(minLength: 2)
                if hovering {
                    ProductivityIconButton(symbol: "xmark", tint: Tokens.faint, help: "Delete") {
                        withAnimation(Tokens.spring) { module.remove(countdown.id) }
                    }
                    .frame(height: 14)
                }
            }
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(r.value).font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                    Text(r.unit).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
                Spacer(minLength: 4)
                ProductivityOrbitView(look: CountdownMath.orbit(countdown.targetDate, now: now), size: 36)
            }
            Text(countdown.targetDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.system(size: 11)).foregroundStyle(Tokens.faint)
            CountdownBar(progress: CountdownMath.progress(created: countdown.createdDate, target: countdown.targetDate, now: now),
                         tint: tint)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete", role: .destructive) { module.remove(countdown.id) } }
    }
}

private struct CountdownForm: View {
    let module: CountdownsAddOn
    @State private var name = ""
    @State private var date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                     of: Date.now.addingTimeInterval(7 * 86_400)) ?? .now

    var body: some View {
        HStack(spacing: 10) {
            ProductivityField(placeholder: "Name, like “Launch day”", text: $name, onSubmit: add)
            DatePicker("", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact).fixedSize()
            GlassPillButton(title: "Cancel") { withAnimation(Tokens.spring) { module.adding = false } }
            PillButton(title: "Add", action: add)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(10)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), selected: true)
    }

    private func add() {
        withAnimation(Tokens.spring) { module.add(title: name, target: date) }
    }
}
