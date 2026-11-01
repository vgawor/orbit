import AppKit
import SwiftUI

/// Seconds per app per day (keyed by bundle id), plus app names. Keeps 7 days.
struct ScreenTimeLog: Codable, Equatable {
    var days: [String: [String: Double]] = [:]
    var names: [String: String] = [:]

    struct Usage: Equatable, Identifiable {
        var id: String { app }
        let app: String
        let seconds: Double
    }

    mutating func add(_ seconds: Double, app: String, name: String, on key: String) {
        days[key, default: [:]][app, default: 0] += seconds
        names[app] = name
    }

    func total(on key: String) -> Double { days[key]?.values.reduce(0, +) ?? 0 }

    /// Most used first.
    func top(on key: String, limit: Int = 6) -> [Usage] {
        (days[key] ?? [:]).map { Usage(app: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.app < $1.app }
            .prefix(limit).map { $0 }
    }

    func name(_ app: String) -> String { names[app] ?? app }

    mutating func prune(now: Date = .now, calendar: Calendar = .current) {
        days = HealthDay.prune(days, keep: 7, now: now, calendar: calendar)
        let used = Set(days.values.flatMap(\.keys))
        names = names.filter { used.contains($0.key) }
    }
}

/// Orbit gets sleepier the longer you've been at the screen today.
enum ScreenTimeOrbit {
    static func mood(hours: Double) -> OrbitView.Mood {
        switch hours {
        case ..<2: .happy
        case ..<5: .normal
        case ..<8: .squint
        default: .closed
        }
    }
    static func motion(hours: Double) -> OrbitView.Motion { hours >= 8 ? .sleep : .idle }
    static func line(hours: Double) -> String {
        switch hours {
        case ..<2: "Orbit's fresh as a daisy"
        case ..<5: "Steady going"
        case ..<8: "Orbit's eyes are getting tired"
        default: "Orbit needs a proper break"
        }
    }
}

/// Screen time: how long each app has been in front today. Doesn't count while you're away or the screen is locked.
@MainActor
@Observable
final class ScreenTimeAddOn: AddOnModule {
    let id = "addon.screentime"
    let title = "Screen time"
    let symbol = "hourglass"
    let addOn = AddOnInfo(category: .health, tier: .pro, summary: "See which apps your day went to, with time per app and a 7-day view.")

    static let tint = Color(red: 1, green: 0.62, blue: 0.35)
    private static let file = "addon-screentime"

    private(set) var log: ScreenTimeLog
    private(set) var isLocked = false
    private let ctx: AddOnContext
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var current: (id: String, name: String)?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var ticks = 0

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            var sample = ScreenTimeLog()
            let apps = [("com.apple.dt.Xcode", "Xcode", 7900.0), ("com.apple.Safari", "Safari", 5400),
                        ("com.tinyspeck.slackmacgap", "Slack", 2900), ("com.apple.mail", "Mail", 1700),
                        ("com.apple.Music", "Music", 900), ("com.apple.finder", "Finder", 420)]
            for (i, key) in HealthDay.lastKeys(7).enumerated() {
                let f = [0.8, 1.1, 0.6, 1.2, 0.9, 0.3, 1.0][i]
                for (id, name, s) in apps { sample.add(s * f, app: id, name: name, on: key) }
            }
            log = sample
        } else {
            log = Storage.load(ScreenTimeLog.self, from: Self.file) ?? ScreenTimeLog()
        }
    }

    var todayKey: String { HealthDay.key(.now) }
    var total: Double { log.total(on: todayKey) }
    var top: [ScreenTimeLog.Usage] { log.top(on: todayKey) }

    func icon(for app: String) -> NSImage? {
        if let cached = icons[app] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[app] = image
        return image
    }

    // MARK: Tracking

    func start() {
        log.prune()
        refreshFrontmost()
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        observe(ws, NSWorkspace.didActivateApplicationNotification) { $0.refreshFrontmost() }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.isLocked = true }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.isLocked = false }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.isLocked = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isLocked = false }
        observe(dist, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(dist, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        save()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (ScreenTimeAddOn) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handle(self) } }
        }
        observers.append((center, token))
    }

    private func refreshFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { current = nil; return }
        let id = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        current = (id, app.localizedName ?? id)
        if icons[id] == nil, let url = app.bundleURL { icons[id] = NSWorkspace.shared.icon(forFile: url.path) }
    }

    private func tick() {
        guard !isLocked, let current, !HealthIdle.isIdle(HealthIdle.seconds()) else { return }
        log.add(1, app: current.id, name: current.name, on: todayKey)
        ticks += 1
        if ticks % 30 == 0 { save() }
    }

    private func save() {
        guard !ModuleRegistry.isPreview else { return }
        log.prune()
        Storage.save(log, to: Self.file)
    }

    var week: [HealthBars.Bar] {
        HealthDay.lastDays(7).map { day in
            let key = HealthDay.key(day)
            return .init(key: key, letter: HealthDay.letter(day), value: log.total(on: key) / 3600)
        }
    }

    // MARK: Views

    var homeCard: AnyView? {
        AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        CardLabel("Screen time")
                        Spacer()
                        OrbitView(size: 34, mood: ScreenTimeOrbit.mood(hours: total / 3600), motion: ScreenTimeOrbit.motion(hours: total / 3600))
                            .padding(.top, -4)
                    }
                    .frame(height: 14)
                    Text(HealthDuration.short(total)).font(.system(size: 22, weight: .semibold, design: .rounded))
                    if let first = top.first {
                        HStack(spacing: 6) {
                            ScreenTimeIcon(image: icon(for: first.app), size: 16)
                            Text("\(log.name(first.app)) · \(HealthDuration.short(first.seconds))")
                                .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                    } else {
                        Text("today").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(ScreenTimePanel(module: self)) }
}

struct ScreenTimeIcon: View {
    let image: NSImage?
    var size: CGFloat = 22
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.7)).foregroundStyle(Tokens.secondary)
                .frame(width: size, height: size)
        }
    }
}

private struct ScreenTimePanel: View {
    let module: ScreenTimeAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Screen time",
                        subtitle: module.total > 0 ? "\(HealthDuration.short(module.total)) in front of your Mac today"
                            : "Counting starts when you use your Mac",
                        tint: ScreenTimeAddOn.tint)
            HStack(alignment: .top, spacing: 12) {
                NotchCard {
                    VStack(alignment: .leading, spacing: 10) {
                        CardLabel("Top apps today")
                        let top = module.top
                        if top.isEmpty {
                            Spacer()
                            VStack(spacing: 8) {
                                OrbitView(size: 56, mood: .happy, motion: reduceMotion ? .still : .idle)
                                Text("Nothing yet today.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            Spacer()
                        } else {
                            let longest = top.first?.seconds ?? 1
                            ForEach(top) { usage in row(usage, longest: longest) }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    NotchCard {
                        let hours = module.total / 3600
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 4) {
                                CardLabel("Total today")
                                Text(HealthDuration.short(module.total))
                                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(module.isLocked ? "Paused while locked" : ScreenTimeOrbit.line(hours: hours))
                                    .font(.system(size: 11)).foregroundStyle(Tokens.faint).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            OrbitView(size: 50, mood: module.isLocked ? .closed : ScreenTimeOrbit.mood(hours: hours),
                                      motion: reduceMotion ? .still : (module.isLocked ? .sleep : ScreenTimeOrbit.motion(hours: hours)))
                        }
                    }
                    .frame(height: 104)
                    NotchCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardLabel("Last 7 days · hours")
                            HealthBars(bars: module.week, tint: ScreenTimeAddOn.tint, height: 190)
                        }
                    }
                }
                .frame(width: 230)
            }
        }
    }

    private func row(_ usage: ScreenTimeLog.Usage, longest: Double) -> some View {
        HStack(spacing: 10) {
            ScreenTimeIcon(image: module.icon(for: usage.app), size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(module.log.name(usage.app)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(HealthDuration.short(usage.seconds)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Tokens.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule().fill(ScreenTimeAddOn.tint.opacity(0.85))
                            .frame(width: max(6, geo.size.width * usage.seconds / max(longest, 1)))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}
