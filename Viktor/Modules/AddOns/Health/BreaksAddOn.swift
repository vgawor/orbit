import SwiftUI

/// What's saved for Eye & posture breaks.
struct BreaksLog: Codable, Equatable {
    var every = 20
    var days: [String: Int] = [:]
    var paused = false

    static let everyRange = 15...60

    mutating func setEvery(_ value: Int) { every = min(max(value, Self.everyRange.lowerBound), Self.everyRange.upperBound) }
    func count(on key: String) -> Int { days[key] ?? 0 }
}

enum BreakKind: Equatable {
    case eyes, posture

    /// Breaks take turns: eyes, posture, eyes…
    static func forBreak(_ index: Int) -> BreakKind { index % 2 == 0 ? .eyes : .posture }

    var title: String {
        switch self {
        case .eyes: "Look at something 20 feet away"
        case .posture: "Shoulders down, sit back"
        }
    }
    var detail: String {
        switch self {
        case .eyes: "for 20 seconds, to rest your eyes"
        case .posture: "Feet flat, screen at eye level"
        }
    }
    var symbol: String {
        switch self {
        case .eyes: "eye"
        case .posture: "figure.seated.side.right"
        }
    }
}

enum BreakSchedule {
    static let countdown: TimeInterval = 20

    /// A break is due `everyMinutes` after the last one, unless paused, snoozed or you're away.
    static func isDue(now: Date, last: Date, everyMinutes: Int, paused: Bool, snoozedUntil: Date?, idleSeconds: TimeInterval) -> Bool {
        if paused || HealthIdle.isIdle(idleSeconds) { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        return now.timeIntervalSince(last) >= Double(everyMinutes) * 60
    }

    /// When the next break comes.
    static func next(last: Date, everyMinutes: Int, snoozedUntil: Date?) -> Date {
        max(last.addingTimeInterval(Double(everyMinutes) * 60), snoozedUntil ?? .distantPast)
    }
}

/// The 20-20-20 rule, taking turns with a posture tip.
@MainActor
@Observable
final class BreaksAddOn: AddOnModule {
    let id = "addon.breaks"
    let title = "Eye & posture breaks"
    let symbol = "eye"
    let addOn = AddOnInfo(category: .health, tier: .free, summary: "The 20-20-20 rule: a short eye break every 20 minutes, with posture tips.")

    static let tint = Color(red: 0.45, green: 0.85, blue: 0.7)
    private static let file = "addon-breaks"

    private(set) var log: BreaksLog
    private(set) var last = Date.now
    private(set) var snoozedUntil: Date?
    /// Set while the 20-second eye break is running.
    private(set) var countdownEnds: Date?
    private(set) var breakIndex = 0
    private(set) var isStarted = false
    private let ctx: AddOnContext
    @ObservationIgnored private var timer: Timer?

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            var sample = BreaksLog()
            sample.days[HealthDay.key(.now)] = 6
            log = sample
            last = .now.addingTimeInterval(-8 * 60)
            isStarted = true
        } else {
            log = Storage.load(BreaksLog.self, from: Self.file) ?? BreaksLog()
        }
    }

    var today: Int { log.count(on: HealthDay.key(.now)) }
    var nextKind: BreakKind { .forBreak(breakIndex) }
    var nextBreak: Date { BreakSchedule.next(last: last, everyMinutes: log.every, snoozedUntil: snoozedUntil) }
    var runningCount: Int { countdownEnds == nil ? 0 : 1 }

    // MARK: Actions

    func startBreak() {
        snoozedUntil = nil
        if nextKind == .eyes {
            countdownEnds = .now.addingTimeInterval(BreakSchedule.countdown)
        } else {
            finishBreak()
        }
    }

    func finishBreak() {
        countdownEnds = nil
        breakIndex += 1
        last = .now
        mutate { $0.days[HealthDay.key(.now), default: 0] += 1 }
    }

    func cancelCountdown() { countdownEnds = nil; last = .now }

    func skip() { breakIndex += 1; last = .now; snoozedUntil = nil }

    func snooze(minutes: Int = 10) { snoozedUntil = .now.addingTimeInterval(Double(minutes) * 60) }

    func togglePause() {
        mutate { $0.paused.toggle() }
        if !log.paused { last = .now; snoozedUntil = nil }
    }

    func changeEvery(by delta: Int) { mutate { $0.setEvery($0.every + delta) } }

    private func mutate(_ change: (inout BreaksLog) -> Void) {
        change(&log)
        log.days = HealthDay.prune(log.days, keep: 30)
        if !ModuleRegistry.isPreview { Storage.save(log, to: Self.file) }
    }

    func start() {
        isStarted = true
        last = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        isStarted = false
        countdownEnds = nil
    }

    private func tick() {
        let now = Date.now
        if let ends = countdownEnds {
            if now >= ends {
                finishBreak()
                ctx.alerts.post(NotchAlert(symbol: "checkmark", tint: Self.tint, title: "Break done",
                                           subtitle: "Back to it. Next one in \(log.every) min",
                                           actions: [.init(title: "OK", isPrimary: true)], duration: 4))
            }
            return
        }
        let idle = HealthIdle.seconds()
        // Being away from the Mac counts as a break for your eyes.
        if HealthIdle.isIdle(idle) { last = now; return }
        guard BreakSchedule.isDue(now: now, last: last, everyMinutes: log.every, paused: log.paused,
                                  snoozedUntil: snoozedUntil, idleSeconds: idle) else { return }
        last = now
        snoozedUntil = nil
        postReminder()
    }

    private func postReminder() {
        let kind = nextKind
        let primary: NotchAlert.Action = kind == .eyes
            ? .init(title: "Start", isPrimary: true) { [weak self] in
                guard let self else { return }
                self.startBreak()
                self.ctx.openPanel(self.id)
            }
            : .init(title: "Done", isPrimary: true) { [weak self] in self?.finishBreak() }
        ctx.alerts.post(NotchAlert(
            symbol: kind.symbol, tint: Self.tint, title: kind.title, subtitle: kind.detail,
            actions: [.init(title: "Later") { [weak self] in self?.snooze() }, primary],
            duration: 8, sound: "Glass"))
    }

    // MARK: Views

    var peekChip: PeekChip? {
        guard let ends = countdownEnds else { return nil }
        let left = max(Int(ends.timeIntervalSinceNow.rounded(.up)), 0)
        return PeekChip(symbol: "eye", text: "Look away · \(left)s", tint: Self.tint, priority: 5)
    }

    var homeCard: AnyView? {
        AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    CardLabel("Breaks")
                    HStack(spacing: 12) {
                        BreaksOrbit(kind: nextKind, state: countdownEnds != nil ? .breakNow : (log.paused || !isStarted ? .resting : .waiting),
                                    size: 40)
                            .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(countdownEnds != nil ? "Looking far away…" : "\(today) \(today == 1 ? "break" : "breaks") today")
                                .font(.system(size: 15, weight: .semibold))
                            Text(log.paused ? "Paused" : "Next: \(nextKind == .eyes ? "eye break" : "posture check") · every \(log.every) min")
                                .font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(BreaksPanel(module: self)) }
}

private struct BreaksPanel: View {
    let module: BreaksAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Eye & posture breaks", subtitle: subtitle, tint: BreaksAddOn.tint)
            HStack(alignment: .top, spacing: 12) {
                main.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    NotchCard {
                        VStack(alignment: .leading, spacing: 6) {
                            CardLabel("Today")
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(module.today)").font(.system(size: 30, weight: .semibold, design: .rounded))
                                Text(module.today == 1 ? "break taken" : "breaks taken")
                                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            }
                            dots
                        }
                    }
                    .frame(height: 120)
                    NotchCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardLabel("Settings")
                            HealthStepper(label: "Break every", value: "\(module.log.every) min",
                                          minus: { module.changeEvery(by: -5) }, plus: { module.changeEvery(by: 5) })
                            Text("No reminders while you're away from the Mac.")
                                .font(.system(size: 11)).foregroundStyle(Tokens.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(width: 250)
            }
        }
    }

    private var subtitle: String {
        if module.log.paused { return "Paused" }
        return "Every \(module.log.every) min: look 20 feet away for 20 seconds"
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<12, id: \.self) { i in
                Circle().fill(i < module.today ? BreaksAddOn.tint : Color.white.opacity(0.1)).frame(width: 9, height: 9)
            }
        }
    }

    private var main: some View {
        NotchCard {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                VStack(spacing: 14) {
                    HStack { CardLabel(module.countdownEnds == nil ? "Next break" : "Eye break"); Spacer() }
                    if let ends = module.countdownEnds {
                        countdown(left: max(ends.timeIntervalSince(context.date), 0))
                    } else {
                        upcoming(now: context.date)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func countdown(left: TimeInterval) -> some View {
        VStack(spacing: 14) {
            ZStack {
                HealthRing(progress: left / BreakSchedule.countdown, tint: BreaksAddOn.tint, lineWidth: 12)
                VStack(spacing: 0) {
                    BreaksOrbit(kind: .eyes, state: .breakNow, size: 58)
                    Text("\(Int(left.rounded(.up)))").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("seconds").font(.system(size: 10)).foregroundStyle(Tokens.secondary)
                }
            }
            .frame(width: 150, height: 150)
            Text("Look at something far away").font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                PillButton(title: "Done") { module.finishBreak() }
                GlassPillButton(title: "Stop") { module.cancelCountdown() }
            }
        }
    }

    private func upcoming(now: Date) -> some View {
        let kind = module.nextKind
        let left = module.nextBreak.timeIntervalSince(now)
        return VStack(spacing: 12) {
            BreaksOrbit(kind: kind, state: module.log.paused || !module.isStarted ? .resting : .waiting, size: 60)
                .frame(width: 84, height: 84).glassSurface(Circle())
            VStack(spacing: 4) {
                Text(kind.title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                Text(kind.detail).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
            }
            Text(status(left: left)).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(module.log.paused ? Tokens.faint : .white)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                PillButton(title: "Take a break now") { module.startBreak() }
                GlassPillButton(title: "Snooze 10 min", symbol: "zzz") { module.snooze() }
                GlassPillButton(title: module.log.paused ? "Resume" : "Pause",
                                symbol: module.log.paused ? "play.fill" : "pause.fill") { module.togglePause() }
            }
        }
    }

    private func status(left: TimeInterval) -> String {
        if module.log.paused { return "Paused" }
        if !module.isStarted { return "Not running" }
        if left <= 0 { return "Now" }
        let m = Int(left) / 60, s = Int(left) % 60
        return String(format: "in %d:%02d", m, s)
    }
}

/// Orbit taking breaks with you: gazing into the distance for eye breaks, stretching tall for posture,
/// dozing while breaks are paused.
struct BreaksOrbit: View {
    enum State { case waiting, breakNow, resting }
    let kind: BreakKind
    let state: State
    var size: CGFloat = 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch (state, kind) {
        case (.resting, _):
            OrbitView(size: size, mood: .closed, motion: reduceMotion ? .still : .sleep)
        case (.breakNow, _), (.waiting, .eyes):
            // Looking far away: eyes up and off to the side, slowly scanning the horizon.
            TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                OrbitView(size: size, mood: state == .breakNow ? .wide : .normal, motion: reduceMotion ? .still : .idle,
                          gaze: CGVector(dx: 0.55 + 0.4 * sin(t * 0.7), dy: -0.7))
            }
        case (.waiting, .posture):
            // A slow stretch: up tall, hold, back down.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let c = t.truncatingRemainder(dividingBy: 4)
                let s = c < 1.6 ? sin(min(c / 0.6, 1) * .pi / 2) * (c > 1.0 ? 1 - (c - 1.0) / 0.6 : 1) : 0
                OrbitView(size: size, mood: s > 0.5 ? .happy : .normal, motion: .still)
                    .scaleEffect(x: 1 - 0.06 * s, y: 1 + 0.12 * s, anchor: .bottom)
            }
        }
    }
}
