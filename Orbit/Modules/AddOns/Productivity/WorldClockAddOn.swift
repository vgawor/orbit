import SwiftUI

/// Clocks for the cities you work with: their time, day or night, and how far ahead or behind you they are.
@MainActor
@Observable
final class WorldClockAddOn: AddOnModule {
    let id = "addon.worldclock"
    let title = "World clock"
    let symbol = "globe"
    let addOn = AddOnInfo(category: .productivity, tier: .free,
                          summary: "See the time where your team and clients are, and whether they're at work.")

    /// Time zone identifiers, e.g. "America/New_York", in the order you added them.
    private(set) var zones: [String] = []
    private(set) var now = Date.now
    var adding = false
    var query = ""

    private let ctx: AddOnContext
    private let storageKey: String?
    private var timer: Timer?

    init(_ ctx: AddOnContext, storageKey: String? = "addon-worldclock") {
        self.ctx = ctx
        self.storageKey = storageKey
        if let storageKey { zones = Storage.load([String].self, from: storageKey) ?? [] }
        if ModuleRegistry.isPreview && storageKey != nil {
            zones = ["Europe/London", "America/New_York", "America/Los_Angeles", "Asia/Tokyo", "Asia/Kolkata"]
        }
    }

    func start() {
        now = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = .now }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Actions

    func add(_ identifier: String) {
        guard TimeZone(identifier: identifier) != nil, !zones.contains(identifier) else { return }
        zones.append(identifier)
        query = ""
        adding = false
        save()
    }

    func remove(_ identifier: String) {
        zones.removeAll { $0 == identifier }
        save()
    }

    var searchResults: [String] { WorldClockMath.search(query, exclude: Set(zones)) }

    private func save() {
        guard let storageKey else { return }
        Storage.save(zones, to: storageKey)
    }

    // MARK: Views

    var panel: AnyView { AnyView(WorldClockPanel(module: self)) }

    var homeCard: AnyView? {
        guard !zones.isEmpty else { return nil }
        return AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 7) {
                    CardLabel("World clock")
                    ForEach(self.zones.prefix(3), id: \.self) { z in
                        if let tz = TimeZone(identifier: z) {
                            HStack(spacing: 6) {
                                ProductivityOrbitView(look: WorldClockMath.orbit(WorldClockMath.workHint(self.now, in: tz)), size: 20)
                                Text(WorldClockMath.cityName(z)).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(WorldClockMath.time(self.now, in: tz)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain))
    }
}

/// The sums and wording behind the world clock. Kept apart so they're easy to test.
enum WorldClockMath {
    /// "America/Argentina/Buenos_Aires" → "Buenos Aires". "UTC" stays "UTC".
    static func cityName(_ identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// "America/Argentina/Buenos_Aires" → "America". Empty for "UTC".
    static func region(_ identifier: String) -> String {
        let parts = identifier.split(separator: "/")
        return parts.count > 1 ? String(parts[0]).replacingOccurrences(of: "_", with: " ") : ""
    }

    /// How far `zone` is from `local` right now: "Same time", "+1 h", "−9 h", "+5 h 30 m".
    static func offsetLabel(_ zone: TimeZone, from local: TimeZone = .current, at date: Date = .now) -> String {
        offsetLabel(seconds: zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date))
    }

    static func offsetLabel(seconds: Int) -> String {
        guard seconds != 0 else { return "Same time" }
        let sign = seconds > 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        if m == 0 { return "\(sign)\(h) h" }
        return h == 0 ? "\(sign)\(m) m" : "\(sign)\(h) h \(m) m"
    }

    static func hour(_ date: Date, in zone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.component(.hour, from: date)
    }

    static func time(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "Tomorrow" or "Yesterday" when that city is already on another day than you, else nil.
    static func dayDifference(_ zone: TimeZone, from local: TimeZone = .current, at date: Date = .now) -> String? {
        func dayNumber(_ tz: TimeZone) -> Int {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        }
        let there = dayNumber(zone), here = dayNumber(local)
        if there > here { return "Tomorrow" }
        if there < here { return "Yesterday" }
        return nil
    }

    /// Light outside between 6:00 and 19:00 (a simple rule; good enough for a glance).
    static func isDaytime(_ hour: Int) -> Bool { (6..<19).contains(hour) }

    enum WorkHint: Equatable {
        case working, early, evening, night, weekend
        var label: String {
            switch self {
            case .working: "Working hours"
            case .early: "Early morning"
            case .evening: "Evening"
            case .night: "Night"
            case .weekend: "Weekend"
            }
        }
        var tint: Color {
            switch self {
            case .working: Tokens.live
            case .early, .evening: Tokens.attention
            case .night, .weekend: Tokens.faint
            }
        }
    }

    /// Is it a good time to reach someone there? Weekdays 9–17 is working time.
    static func workHint(hour: Int, weekday: Int) -> WorkHint {
        if weekday == 1 || weekday == 7 { return .weekend }   // Sunday, Saturday
        switch hour {
        case 9..<17: return .working
        case 7..<9: return .early
        case 17..<22: return .evening
        default: return .night
        }
    }

    /// Orbit living in that city: busy in working hours, sleepy early, relaxed in the evening and at weekends, asleep at night.
    static func orbit(_ hint: WorkHint) -> ProductivityOrbit {
        switch hint {
        case .working: ProductivityOrbit(mood: .normal, motion: .working)
        case .early: ProductivityOrbit(mood: .squint, motion: .idle)
        case .evening: .happy
        case .weekend: ProductivityOrbit(mood: .happy, motion: .glow, tint: Tokens.live)
        case .night: .asleep
        }
    }

    static func workHint(_ date: Date, in zone: TimeZone) -> WorkHint {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return workHint(hour: cal.component(.hour, from: date), weekday: cal.component(.weekday, from: date))
    }

    /// Time zones whose city or region matches the search (any case, any accents), best matches first.
    static func search(_ query: String, in identifiers: [String] = TimeZone.knownTimeZoneIdentifiers,
                       exclude: Set<String> = [], limit: Int = 30) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let pool = identifiers.filter { !exclude.contains($0) && $0.contains("/") && !$0.hasPrefix("Etc/") }
        guard !q.isEmpty else { return Array(pool.prefix(limit)) }
        let normalized = q.replacingOccurrences(of: " ", with: "_")
        let starts = pool.filter { cityName($0).range(of: q, options: options.union(.anchored)) != nil }
        let contains = pool.filter { !starts.contains($0) && $0.range(of: normalized, options: options) != nil }
        return Array((starts + contains).prefix(limit))
    }
}

// MARK: - Panel

private struct WorldClockPanel: View {
    let module: WorldClockAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AddOnHeader(symbol: module.symbol, title: "World clock", subtitle: subtitle, tint: ProductivityAddOns.tint)
                if module.adding {
                    GlassPillButton(title: "Done") { withAnimation(Tokens.spring) { module.adding = false } }
                } else {
                    PillButton(title: "Add city") { withAnimation(Tokens.spring) { module.adding = true } }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                clocks
                if module.adding {
                    WorldClockSearch(module: module)
                        .frame(width: 260)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Tokens.spring, value: module.adding)
        }
    }

    private var subtitle: String {
        let here = TimeZone.current
        return "Your time \(WorldClockMath.time(module.now, in: here)) · \(WorldClockMath.cityName(here.identifier))"
    }

    @ViewBuilder private var clocks: some View {
        if module.zones.isEmpty {
            VStack(spacing: 8) {
                WorldClockGlobeOrbit()
                Text("No cities yet").font(.system(size: 13, weight: .semibold))
                Text("Add the cities your team and clients are in.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(24)
        } else {
            let columns = module.adding ? 2 : 3
            let rows = Array(stride(from: 0, to: module.zones.count, by: columns))
            NotchScroll {
                VStack(spacing: 10) {
                    ForEach(rows, id: \.self) { start in
                        HStack(spacing: 10) {
                            ForEach(module.zones[start..<min(start + columns, module.zones.count)], id: \.self) {
                                WorldClockTile(identifier: $0, module: module)
                            }
                            ForEach(0..<max(0, start + columns - module.zones.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct WorldClockTile: View {
    let identifier: String
    let module: WorldClockAddOn
    @State private var hovering = false

    var body: some View {
        let tz = TimeZone(identifier: identifier) ?? .current
        let now = module.now
        let hour = WorldClockMath.hour(now, in: tz)
        let hint = WorldClockMath.workHint(now, in: tz)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: WorldClockMath.isDaytime(hour) ? "sun.max.fill" : "moon.stars.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(WorldClockMath.isDaytime(hour) ? Tokens.attention : Color(red: 0.7, green: 0.75, blue: 1))
                Text(WorldClockMath.cityName(identifier)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if hovering {
                    ProductivityIconButton(symbol: "xmark", tint: Tokens.faint, help: "Remove") {
                        withAnimation(Tokens.spring) { module.remove(identifier) }
                    }
                    .frame(height: 14)
                }
            }
            HStack(alignment: .center, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(WorldClockMath.time(now, in: tz)).font(.system(size: 28, weight: .semibold).monospacedDigit())
                    if let day = WorldClockMath.dayDifference(tz, at: now) {
                        Text(day).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.secondary)
                    }
                }
                Spacer(minLength: 4)
                ProductivityOrbitView(look: WorldClockMath.orbit(hint), size: 38)
                    .help(hint == .night ? "Orbit's asleep in \(WorldClockMath.cityName(identifier))" : hint.label)
            }
            HStack(spacing: 6) {
                Text(WorldClockMath.offsetLabel(tz, at: now)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.secondary)
                Circle().fill(hint.tint).frame(width: 5, height: 5)
                Text(hint.label).font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove", role: .destructive) { module.remove(identifier) } }
    }
}

private struct WorldClockSearch: View {
    let module: WorldClockAddOn

    var body: some View {
        @Bindable var module = module
        let results = module.searchResults
        VStack(alignment: .leading, spacing: 8) {
            ProductivityField(placeholder: "Search a city", text: $module.query, symbol: "magnifyingglass") {
                if let first = results.first { withAnimation(Tokens.spring) { module.add(first) } }
            }
            NotchScroll {
                VStack(alignment: .leading, spacing: 1) {
                    if results.isEmpty {
                        Text("No city found. Try a bigger city nearby.")
                            .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).padding(8)
                    }
                    ForEach(results, id: \.self) { z in
                        WorldClockResultRow(identifier: z, now: module.now) { withAnimation(Tokens.spring) { module.add(z) } }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), selected: true)
    }
}

private struct WorldClockResultRow: View {
    let identifier: String
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tz = TimeZone(identifier: identifier) ?? .current
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WorldClockMath.cityName(identifier)).font(.system(size: 12.5)).lineLimit(1)
                    Text(WorldClockMath.region(identifier)).font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                }
                Spacer(minLength: 4)
                Text(WorldClockMath.time(now, in: tz)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tokens.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Orbit circling a little globe, waiting for you to pick some cities.
private struct WorldClockGlobeOrbit: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let a = reduceMotion ? 0.35 : timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 6
            let behind = sin(a) < 0
            ZStack {
                Ellipse().stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .frame(width: 112, height: 30)
                    .rotationEffect(.degrees(-12))
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(ProductivityAddOns.tint.opacity(0.85))
                    .zIndex(1)
                OrbitView(size: 28, mood: .happy, motion: .still)
                    .scaleEffect(behind ? 0.8 : 1)
                    .opacity(behind ? 0.55 : 1)
                    .offset(x: 56 * cos(a), y: 15 * sin(a) - 11 * cos(a))
                    .zIndex(behind ? 0 : 2)
            }
        }
        .frame(width: 140, height: 70)
        .accessibilityLabel("Orbit circling a globe")
    }
}
