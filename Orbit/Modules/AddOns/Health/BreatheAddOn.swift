import SwiftUI

/// A breathing rhythm: a few phases that repeat.
enum BreathPattern: String, CaseIterable, Codable, Identifiable {
    case box, relax

    var id: String { rawValue }
    var title: String {
        switch self {
        case .box: "Box 4-4-4-4"
        case .relax: "Relax 4-7-8"
        }
    }
    var phases: [BreathPhase] {
        switch self {
        case .box: [.init(kind: .breatheIn, seconds: 4), .init(kind: .hold, seconds: 4),
                    .init(kind: .breatheOut, seconds: 4), .init(kind: .holdOut, seconds: 4)]
        case .relax: [.init(kind: .breatheIn, seconds: 4), .init(kind: .hold, seconds: 7),
                      .init(kind: .breatheOut, seconds: 8)]
        }
    }
    /// Seconds for one round of all phases.
    var cycle: Double { phases.reduce(0) { $0 + $1.seconds } }
}

struct BreathPhase: Equatable {
    enum Kind: Equatable { case breatheIn, hold, breatheOut, holdOut }
    let kind: Kind
    let seconds: Double

    var label: String {
        switch kind {
        case .breatheIn: "Breathe in"
        case .hold, .holdOut: "Hold"
        case .breatheOut: "Breathe out"
        }
    }
}

/// Where you are in the rhythm at a moment.
struct BreathMoment: Equatable {
    let phase: BreathPhase
    let index: Int
    /// 0…1 through this phase.
    let progress: Double
    /// Whole seconds left in this phase (4, 3, 2, 1).
    let secondsLeft: Int
    /// How big the circle is: 0.5 empty … 1 full.
    let scale: Double
}

enum BreathGuide {
    static let small = 0.5

    /// Orbit breathes along: eyes wide breathing in, open while holding, closed breathing out and resting.
    static func orbitMood(_ kind: BreathPhase.Kind) -> OrbitView.Mood {
        switch kind {
        case .breatheIn: .wide
        case .hold: .normal
        case .breatheOut, .holdOut: .closed
        }
    }

    /// Ring glows while the breath is in, rests dim and bright on the empty hold, keeps still breathing out.
    static func orbitMotion(_ kind: BreathPhase.Kind) -> OrbitView.Motion {
        switch kind {
        case .breatheIn, .hold: .glow
        case .breatheOut: .still
        case .holdOut: .sleep
        }
    }

    /// Orbit's size for a breath scale (0.5 empty … 1 full): about 62 % … 100 %.
    static func orbitScale(_ scale: Double) -> Double { 0.62 + (min(max(scale, small), 1) - small) * 0.76 }

    static func moment(_ pattern: BreathPattern, elapsed: Double) -> BreathMoment {
        let phases = pattern.phases
        var t = elapsed.truncatingRemainder(dividingBy: pattern.cycle)
        if t < 0 { t += pattern.cycle }
        var index = 0
        while index < phases.count - 1, t >= phases[index].seconds {
            t -= phases[index].seconds
            index += 1
        }
        let phase = phases[index]
        let p = min(max(t / phase.seconds, 0), 1)
        let eased = 0.5 - cos(p * .pi) / 2
        let scale: Double = switch phase.kind {
        case .breatheIn: small + (1 - small) * eased
        case .hold: 1
        case .breatheOut: 1 - (1 - small) * eased
        case .holdOut: small
        }
        return BreathMoment(phase: phase, index: index, progress: p,
                            secondsLeft: max(Int((phase.seconds - t).rounded(.up)), 1), scale: scale)
    }
}

struct BreatheLog: Codable, Equatable {
    var pattern: BreathPattern = .box
    var minutes = 3
    var days: [String: Int] = [:]
    static let lengths = [1, 3, 5]
}

/// Breathing: an animated guide for box and 4-7-8 breathing.
@MainActor
@Observable
final class BreatheAddOn: AddOnModule {
    let id = "addon.breathe"
    let title = "Breathe"
    let symbol = "wind"
    let addOn = AddOnInfo(category: .health, tier: .free, summary: "A calm breathing guide: box breathing or 4-7-8, for 1, 3 or 5 minutes.")

    static let tint = Color(red: 0.6, green: 0.62, blue: 1)
    private static let file = "addon-breathe"

    private(set) var log: BreatheLog
    private(set) var startedAt: Date?
    private(set) var justFinished = false
    private let ctx: AddOnContext
    @ObservationIgnored private var timer: Timer?

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            var sample = BreatheLog()
            sample.days[HealthDay.key(.now)] = 2
            log = sample
        } else {
            log = Storage.load(BreatheLog.self, from: Self.file) ?? BreatheLog()
        }
    }

    var today: Int { log.days[HealthDay.key(.now)] ?? 0 }
    var isRunning: Bool { startedAt != nil }
    var runningCount: Int { isRunning ? 1 : 0 }
    var length: Double { Double(log.minutes) * 60 }

    func setPattern(_ p: BreathPattern) { guard !isRunning else { return }; mutate { $0.pattern = p } }
    func setMinutes(_ m: Int) { guard !isRunning else { return }; mutate { $0.minutes = m } }

    func begin() {
        justFinished = false
        startedAt = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func end() {
        timer?.invalidate(); timer = nil
        startedAt = nil
    }

    private func tick() {
        guard let startedAt, Date.now.timeIntervalSince(startedAt) >= length else { return }
        end()
        justFinished = true
        mutate { $0.days[HealthDay.key(.now), default: 0] += 1 }
    }

    private func mutate(_ change: (inout BreatheLog) -> Void) {
        change(&log)
        log.days = HealthDay.prune(log.days, keep: 30)
        if !ModuleRegistry.isPreview { Storage.save(log, to: Self.file) }
    }

    func stop() { end() }

    var peekChip: PeekChip? {
        isRunning ? PeekChip(symbol: "wind", text: "Breathing", tint: Self.tint, priority: 4) : nil
    }

    var homeCard: AnyView? {
        AnyView(Button { self.ctx.openPanel(self.id) } label: {
            NotchCard { BreatheHomeCard(module: self) }
        }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(BreathePanel(module: self)) }
}

private struct BreathePanel: View {
    let module: BreatheAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Breathe",
                        subtitle: module.today == 0 ? "A minute of slow breathing can help you reset"
                            : "\(module.today) \(module.today == 1 ? "session" : "sessions") today",
                        tint: BreatheAddOn.tint)
            HStack(alignment: .top, spacing: 12) {
                NotchCard { guide }.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    NotchCard {
                        VStack(alignment: .leading, spacing: 8) {
                            CardLabel("Rhythm")
                            ForEach(BreathPattern.allCases) { p in
                                option(p.title, selected: module.log.pattern == p) { module.setPattern(p) }
                            }
                        }
                    }
                    .frame(height: 118)
                    NotchCard {
                        VStack(alignment: .leading, spacing: 8) {
                            CardLabel("Length")
                            HStack(spacing: 6) {
                                ForEach(BreatheLog.lengths, id: \.self) { m in
                                    chip("\(m) min", selected: module.log.minutes == m) { module.setMinutes(m) }
                                }
                            }
                        }
                    }
                    .frame(height: 86)
                    NotchCard {
                        VStack(alignment: .leading, spacing: 4) {
                            CardLabel("Today")
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(module.today)").font(.system(size: 26, weight: .semibold, design: .rounded))
                                Text(module.today == 1 ? "session done" : "sessions done")
                                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("Breathe in through your nose, slowly out through your mouth.")
                                .font(.system(size: 11)).foregroundStyle(Tokens.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(width: 230)
                .opacity(module.isRunning ? 0.5 : 1)
                .disabled(module.isRunning)
            }
        }
    }

    private var guide: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !module.isRunning)) { context in
            let elapsed = module.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            let moment = BreathGuide.moment(module.log.pattern, elapsed: elapsed)
            VStack(spacing: 10) {
                HStack {
                    CardLabel(module.isRunning ? module.log.pattern.title : "Ready")
                    Spacer()
                    if module.isRunning {
                        Text(timeLeft(elapsed)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Tokens.secondary)
                    }
                }
                BreatheOrbit(moment: module.isRunning ? moment : nil, finished: module.justFinished, size: 120)
                    .frame(height: 196)
                VStack(spacing: 2) {
                    Text(module.isRunning ? moment.phase.label : (module.justFinished ? "Well done" : "Breathe with Orbit"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(module.isRunning ? "\(moment.secondsLeft)" : (module.justFinished ? "Orbit feels calmer too" : "In as it grows, out as it shrinks"))
                        .font(.system(size: module.isRunning ? 13 : 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(module.isRunning ? .white.opacity(0.75) : Tokens.secondary)
                }
                Spacer(minLength: 0)
                if module.isRunning {
                    GlassPillButton(title: "Stop", symbol: "stop.fill") { module.end() }
                } else {
                    PillButton(title: module.justFinished ? "Go again" : "Start \(module.log.minutes) min") { module.begin() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func timeLeft(_ elapsed: Double) -> String {
        let left = max(Int(module.length - elapsed), 0)
        return String(format: "%d:%02d left", left / 60, left % 60)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(selected ? .white : Tokens.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassSurface(Capsule(), selected: selected)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Tokens.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .glassSurface(Capsule(), selected: selected)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Orbit as the breathing guide: it sits in a soft circle that fills as you breathe in, growing with it,
/// eyes open on the way in and closed on the way out. `moment` nil = resting, waiting to start.
struct BreatheOrbit: View {
    let moment: BreathMoment?
    var finished = false
    var size: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let aura = size * 1.58
        // With Reduce Motion, nothing grows: a ring fills round the phase instead.
        let scale = moment.map { reduceMotion ? 0.85 : $0.scale } ?? 0.72
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).frame(width: aura, height: aura)
            Circle()
                .fill(RadialGradient(colors: [BreatheAddOn.tint.opacity(0.6), BreatheAddOn.tint.opacity(0.12)],
                                     center: .center, startRadius: 0, endRadius: aura / 2))
                .frame(width: aura, height: aura)
                .scaleEffect(scale)
                .shadow(color: BreatheAddOn.tint.opacity(0.4), radius: 22)
            if let moment, reduceMotion {
                Circle().trim(from: 0, to: moment.progress)
                    .stroke(BreatheAddOn.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: aura + 6, height: aura + 6)
            }
            orbit
                .scaleEffect(BreathGuide.orbitScale(scale))
        }
        .compositingGroup()
        .accessibilityElement()
        .accessibilityLabel(moment.map { "Orbit: \($0.phase.label)" } ?? "Orbit, ready to breathe")
    }

    @ViewBuilder private var orbit: some View {
        if let moment {
            OrbitView(size: size, mood: BreathGuide.orbitMood(moment.phase.kind),
                      motion: reduceMotion ? .still : BreathGuide.orbitMotion(moment.phase.kind), tint: BreatheAddOn.tint)
        } else {
            OrbitView(size: size, mood: finished ? .happy : .normal, motion: reduceMotion ? .still : .idle)
        }
    }
}

/// Home: a tiny Orbit breathing along while a session runs, otherwise today's count.
private struct BreatheHomeCard: View {
    let module: BreatheAddOn

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !module.isRunning)) { context in
            let elapsed = module.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            let moment = BreathGuide.moment(module.log.pattern, elapsed: elapsed)
            VStack(alignment: .leading, spacing: 8) {
                CardLabel("Breathe")
                HStack(spacing: 12) {
                    BreatheOrbit(moment: module.isRunning ? moment : nil, finished: module.justFinished, size: 30)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        if module.isRunning {
                            Text(moment.phase.label).font(.system(size: 15, weight: .semibold))
                            Text("\(moment.secondsLeft) · \(module.log.pattern.title)")
                                .font(.system(size: 11)).foregroundStyle(Tokens.secondary).monospacedDigit()
                        } else {
                            Text(module.today == 0 ? "Take a breather" : "\(module.today) \(module.today == 1 ? "session" : "sessions") today")
                                .font(.system(size: 15, weight: .semibold))
                            Text("\(module.log.pattern.title) · \(module.log.minutes) min")
                                .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
