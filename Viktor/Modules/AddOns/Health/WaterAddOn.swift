import SwiftUI

/// What's saved for Water: the goal, glasses per day and the reminder.
struct WaterLog: Codable, Equatable {
    var goal = 8
    var days: [String: Int] = [:]
    var remind = false
    var remindEvery = 60

    static let goalRange = 1...20
    static let remindRange = 15...180

    func count(on key: String) -> Int { days[key] ?? 0 }

    mutating func add(on key: String) { days[key, default: 0] += 1 }

    mutating func undo(on key: String) {
        let n = count(on: key)
        days[key] = n > 1 ? n - 1 : nil
    }

    mutating func setGoal(_ value: Int) { goal = min(max(value, Self.goalRange.lowerBound), Self.goalRange.upperBound) }
    mutating func setRemindEvery(_ value: Int) {
        remindEvery = min(max(value, Self.remindRange.lowerBound), Self.remindRange.upperBound)
    }

    func progress(on key: String) -> Double { goal > 0 ? Double(count(on: key)) / Double(goal) : 0 }
}

/// How Orbit feels about today's water: a bit parched at first, cheerier with every glass.
enum WaterOrbit {
    static func mood(progress: Double) -> OrbitView.Mood {
        switch progress {
        case ..<0.01: .squint
        case ..<0.5: .normal
        case ..<1: .wink
        default: .happy
        }
    }
    /// Glows in water blue once the goal is reached.
    static func motion(progress: Double) -> OrbitView.Motion { progress >= 1 ? .glow : .idle }

    static func line(progress: Double) -> String {
        switch progress {
        case ..<0.01: "Orbit's a little parched"
        case ..<0.5: "Off to a good start"
        case ..<1: "Orbit's feeling fresh"
        default: "Fully hydrated!"
        }
    }
}

enum WaterReminder {
    /// Reminders only go out in the day (9:00–18:00), `everyMinutes` after the last glass or reminder.
    static func isDue(now: Date, last: Date, everyMinutes: Int, from startHour: Int = 9, to endHour: Int = 18,
                      calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour >= startHour, hour < endHour else { return false }
        return now.timeIntervalSince(last) >= Double(everyMinutes) * 60
    }
}

/// Water: count glasses towards a daily goal, with an optional reminder.
@MainActor
@Observable
final class WaterAddOn: AddOnModule {
    let id = "addon.water"
    let title = "Water"
    let symbol = "drop.fill"
    let addOn = AddOnInfo(category: .health, tier: .free, summary: "Count glasses of water towards a daily goal, with gentle reminders.")

    static let tint = Color(red: 0.35, green: 0.72, blue: 1)
    private static let file = "addon-water"

    private(set) var log: WaterLog
    private let ctx: AddOnContext
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastNudge = Date.now

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            var sample = WaterLog()
            for (i, key) in HealthDay.lastKeys(7).enumerated() { sample.days[key] = [6, 8, 5, 9, 7, 8, 5][i] }
            sample.remind = true
            log = sample
        } else {
            log = Storage.load(WaterLog.self, from: Self.file) ?? WaterLog()
        }
    }

    var today: Int { log.count(on: HealthDay.key(.now)) }

    func addGlass() { mutate { $0.add(on: HealthDay.key(.now)) }; lastNudge = .now }
    func undo() { mutate { $0.undo(on: HealthDay.key(.now)) } }
    func changeGoal(by delta: Int) { mutate { $0.setGoal($0.goal + delta) } }
    func changeReminder(by delta: Int) { mutate { $0.setRemindEvery($0.remindEvery + delta) } }
    func toggleReminder() { mutate { $0.remind.toggle() }; lastNudge = .now }

    private func mutate(_ change: (inout WaterLog) -> Void) {
        change(&log)
        log.days = HealthDay.prune(log.days, keep: 30)
        if !ModuleRegistry.isPreview { Storage.save(log, to: Self.file) }
    }

    func start() {
        lastNudge = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard log.remind, today < log.goal, !HealthIdle.isIdle(HealthIdle.seconds()),
              WaterReminder.isDue(now: .now, last: lastNudge, everyMinutes: log.remindEvery) else { return }
        lastNudge = .now
        ctx.alerts.post(NotchAlert(
            symbol: "drop.fill", tint: Self.tint, title: "Time for some water",
            subtitle: "\(today) of \(log.goal) glasses today",
            actions: [.init(title: "Later"), .init(title: "+ Glass", isPrimary: true) { [weak self] in self?.addGlass() }],
            duration: 6, sound: "Glass"))
    }

    var history: [HealthBars.Bar] {
        HealthDay.lastDays(7).map { day in
            let key = HealthDay.key(day)
            return .init(key: key, letter: HealthDay.letter(day), value: Double(log.count(on: key)))
        }
    }

    // MARK: Views

    var peekChip: PeekChip? {
        today > 0 ? PeekChip(symbol: "drop.fill", text: "\(today)/\(log.goal)", tint: Self.tint, priority: 1) : nil
    }

    var homeCard: AnyView? {
        AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("Water")
                    HStack(spacing: 12) {
                        let progress = log.progress(on: HealthDay.key(.now))
                        ZStack {
                            HealthRing(progress: progress, tint: Self.tint, lineWidth: 5)
                            OrbitView(size: 30, mood: WaterOrbit.mood(progress: progress),
                                      motion: WaterOrbit.motion(progress: progress), tint: Self.tint)
                        }
                        .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(today) of \(log.goal) glasses").font(.system(size: 15, weight: .semibold))
                            Text(WaterOrbit.line(progress: progress))
                                .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(WaterPanel(module: self)) }
}

private struct WaterPanel: View {
    let module: WaterAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var left: Int { max(module.log.goal - module.today, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Water",
                        subtitle: left == 0 ? "Goal reached. Nice work." : "\(left) more \(left == 1 ? "glass" : "glasses") to reach your goal",
                        tint: WaterAddOn.tint)
            HStack(alignment: .top, spacing: 12) {
                today.frame(width: 260)
                VStack(spacing: 12) {
                    NotchCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardLabel("Last 7 days")
                            HealthBars(bars: module.history, tint: WaterAddOn.tint, goal: Double(module.log.goal), height: 84)
                        }
                    }
                    .frame(height: 150)
                    NotchCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardLabel("Settings")
                            HealthStepper(label: "Daily goal", value: "\(module.log.goal) glasses",
                                          minus: { module.changeGoal(by: -1) }, plus: { module.changeGoal(by: 1) })
                            HealthSwitch(label: "Remind me (9:00–18:00)", isOn: module.log.remind, tint: WaterAddOn.tint) {
                                module.toggleReminder()
                            }
                            HealthStepper(label: "Every", value: "\(module.log.remindEvery) min",
                                          minus: { module.changeReminder(by: -15) }, plus: { module.changeReminder(by: 15) })
                                .opacity(module.log.remind ? 1 : 0.4)
                                .disabled(!module.log.remind)
                        }
                    }
                }
            }
        }
    }

    private var today: some View {
        let progress = module.log.progress(on: HealthDay.key(.now))
        return NotchCard {
            VStack(spacing: 12) {
                HStack { CardLabel("Today"); Spacer() }
                HStack(alignment: .bottom, spacing: 10) {
                    OrbitView(size: 92, mood: WaterOrbit.mood(progress: progress),
                              motion: reduceMotion ? .still : WaterOrbit.motion(progress: progress), tint: WaterAddOn.tint)
                    WaterGlass(progress: progress).frame(width: 60, height: 88)
                }
                .compositingGroup()
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(module.today)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of \(module.log.goal) glasses").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    }
                    Text(WaterOrbit.line(progress: progress)).font(.system(size: 11)).foregroundStyle(Tokens.faint)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    PillButton(title: "+ Glass") { module.addGlass() }
                    GlassPillButton(title: "Undo", symbol: "arrow.uturn.backward") { module.undo() }
                        .opacity(module.today > 0 ? 1 : 0.4)
                        .disabled(module.today == 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A glass that fills up as you drink, with a gently moving surface.
struct WaterGlass: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width, h = size.height, inset = w * 0.12
                var glass = Path()
                glass.move(to: CGPoint(x: 0, y: 0))
                glass.addLine(to: CGPoint(x: w, y: 0))
                glass.addLine(to: CGPoint(x: w - inset, y: h))
                glass.addLine(to: CGPoint(x: inset, y: h))
                glass.closeSubpath()
                let level = min(max(progress, 0), 1)
                if level > 0 {
                    let top = h - (h - 6) * level
                    var water = Path()
                    water.move(to: CGPoint(x: 0, y: top))
                    for i in 0...20 {
                        let x = w * Double(i) / 20
                        water.addLine(to: CGPoint(x: x, y: top + sin(x / w * 2 * .pi * 1.5 + t * 2.2) * (level < 1 ? 2 : 1.2)))
                    }
                    water.addLine(to: CGPoint(x: w, y: h)); water.addLine(to: CGPoint(x: 0, y: h)); water.closeSubpath()
                    var inside = ctx
                    inside.clip(to: glass)
                    inside.fill(water, with: .linearGradient(Gradient(colors: [WaterAddOn.tint.opacity(0.95), WaterAddOn.tint.opacity(0.55)]),
                                                             startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
                }
                ctx.fill(glass, with: .color(.white.opacity(0.06)))
                ctx.stroke(glass, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                // A shine down one side.
                var shine = Path()
                shine.move(to: CGPoint(x: w * 0.2, y: h * 0.12)); shine.addLine(to: CGPoint(x: w * 0.27, y: h * 0.75))
                ctx.stroke(shine, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .animation(Tokens.spring, value: progress)
        .accessibilityHidden(true)
    }
}
