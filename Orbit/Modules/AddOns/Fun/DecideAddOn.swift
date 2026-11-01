import SwiftUI

/// The pure part of the decision maker: coins, dice and picking from a list.
enum DecideLogic {
    enum Mode: String, Codable, CaseIterable { case coin, dice, pick }

    enum Dice: String, Codable, CaseIterable {
        case d6, d20, twoD6
        var title: String {
            switch self {
            case .d6: "d6"
            case .d20: "d20"
            case .twoD6: "2 × d6"
            }
        }
        var sides: Int { self == .d20 ? 20 : 6 }
        var count: Int { self == .twoD6 ? 2 : 1 }
    }

    /// True = heads.
    static func flip<R: RandomNumberGenerator>(using rng: inout R) -> Bool { Bool.random(using: &rng) }

    static func roll<R: RandomNumberGenerator>(_ dice: Dice, using rng: inout R) -> [Int] {
        (0..<dice.count).map { _ in Int.random(in: 1...dice.sides, using: &rng) }
    }

    /// Splits typed text into options: commas or new lines, trimmed, blanks dropped.
    static func options(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func pick<R: RandomNumberGenerator>(from count: Int, using rng: inout R) -> Int? {
        count > 0 ? Int.random(in: 0..<count, using: &rng) : nil
    }

    /// The waits (seconds) between frames of a spin that slows down before it lands.
    static func spinDelays(steps: Int) -> [Double] {
        (0..<max(steps, 0)).map { i in
            let t = Double(i) / Double(max(steps - 1, 1))
            return 0.045 + 0.24 * t * t
        }
    }

    /// The pip spots (0…1 in a die face) for 1–6.
    static func pips(_ value: Int) -> [CGPoint] {
        let l = 0.27, m = 0.5, r = 0.73
        switch value {
        case 1: return [CGPoint(x: m, y: m)]
        case 2: return [CGPoint(x: l, y: l), CGPoint(x: r, y: r)]
        case 3: return [CGPoint(x: l, y: l), CGPoint(x: m, y: m), CGPoint(x: r, y: r)]
        case 4: return [CGPoint(x: l, y: l), CGPoint(x: r, y: l), CGPoint(x: l, y: r), CGPoint(x: r, y: r)]
        case 5: return [CGPoint(x: l, y: l), CGPoint(x: r, y: l), CGPoint(x: m, y: m), CGPoint(x: l, y: r), CGPoint(x: r, y: r)]
        case 6: return [CGPoint(x: l, y: l), CGPoint(x: r, y: l), CGPoint(x: l, y: m), CGPoint(x: r, y: m), CGPoint(x: l, y: r), CGPoint(x: r, y: r)]
        default: return []
        }
    }
}

/// Decision maker: flip a coin, roll dice, or let Orbit pick one from a list.
@MainActor
@Observable
final class DecideAddOn: AddOnModule {
    let id = "addon.decide"
    let title = "Decide"
    let symbol = "dice.fill"
    let addOn = AddOnInfo(category: .fun, tier: .free,
                          summary: "Flip a coin, roll dice or pick one from a list when you can't choose.")

    private struct Saved: Codable {
        var mode: DecideLogic.Mode
        var dice: DecideLogic.Dice
        var list: String
    }

    var mode: DecideLogic.Mode { didSet { save() } }
    var dice: DecideLogic.Dice { didSet { if dice != oldValue { values = Array(repeating: dice.sides, count: dice.count); save() } } }
    var list: String { didSet { save() } }

    // Coin
    private(set) var coinAngle: Double = 0
    private(set) var heads: Bool?
    // Dice
    private(set) var values: [Int] = [6]
    private(set) var wobble: Double = 0
    // Pick
    private(set) var highlighted: Int?
    private(set) var chosen: String?

    private(set) var busy = false
    private var spin: Task<Void, Never>?
    private let openPanel: @MainActor (String) -> Void

    init(openPanel: @escaping @MainActor (String) -> Void = { _ in }) {
        self.openPanel = openPanel
        let saved = Storage.load(Saved.self, from: "addon-decide")
        mode = saved?.mode ?? .coin
        dice = saved?.dice ?? .d6
        list = saved?.list ?? "Pizza, Sushi, Tacos, Ramen"
        values = Array(repeating: dice == .d20 ? 20 : 6, count: dice.count)
        if ModuleRegistry.isPreview { mode = .pick; chosen = "Sushi"; highlighted = 1 }
    }

    private func save() {
        Storage.save(Saved(mode: mode, dice: dice, list: list), to: "addon-decide")
    }

    var options: [String] { DecideLogic.options(from: list) }

    func stop() { spin?.cancel(); busy = false }

    // MARK: Actions

    func flipCoin(reduceMotion: Bool) {
        guard !busy else { return }
        var rng = SystemRandomNumberGenerator()
        let result = DecideLogic.flip(using: &rng)
        heads = nil
        // Land on 0° (heads) or 180° (tails) after a few full turns.
        let base = (coinAngle / 360).rounded(.down) * 360
        let target = base + (reduceMotion ? 0 : 360 * 5) + (result ? 360 : 540)
        busy = true
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.2, 0.7, 0.25, 1, duration: 1.3)) {
            coinAngle = target
        }
        spin = Task { [weak self] in
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 1.3))
            guard let self, !Task.isCancelled else { return }
            withAnimation(Tokens.spring) { self.heads = result }
            self.busy = false
        }
    }

    func rollDice(reduceMotion: Bool) {
        guard !busy else { return }
        var rng = SystemRandomNumberGenerator()
        let result = DecideLogic.roll(dice, using: &rng)
        let kind = dice
        busy = true
        spin = Task { [weak self] in
            if !reduceMotion {
                for (i, delay) in DecideLogic.spinDelays(steps: 12).enumerated() {
                    guard let self, !Task.isCancelled else { return }
                    var r = SystemRandomNumberGenerator()
                    self.values = DecideLogic.roll(kind, using: &r)
                    withAnimation(.easeOut(duration: delay)) { self.wobble = i.isMultiple(of: 2) ? 14 : -14 }
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { self.wobble = 0; self.values = result }
            self.busy = false
        }
    }

    func pickOne(reduceMotion: Bool) {
        let items = options
        guard !busy, !items.isEmpty else { return }
        var rng = SystemRandomNumberGenerator()
        guard let winner = DecideLogic.pick(from: items.count, using: &rng) else { return }
        busy = true
        chosen = nil
        let delays = reduceMotion ? [] : DecideLogic.spinDelays(steps: 14 + items.count)
        // Walk through the names so the spin ends on the winner.
        let start = ((winner - delays.count) % items.count + items.count) % items.count
        spin = Task { [weak self] in
            for (i, delay) in delays.enumerated() {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.08)) { self.highlighted = (start + i) % items.count }
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                self.highlighted = winner
                self.chosen = items[winner]
            }
            self.busy = false
        }
    }

    func go(reduceMotion: Bool) {
        switch mode {
        case .coin: flipCoin(reduceMotion: reduceMotion)
        case .dice: rollDice(reduceMotion: reduceMotion)
        case .pick: pickOne(reduceMotion: reduceMotion)
        }
    }

    var homeCard: AnyView? {
        AnyView(Button { self.openPanel(self.id) } label: { NotchCard { DecideHomeCard(model: self) } }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(DecidePanel(model: self)) }
}

/// Home: a quick coin flip right on the card, with Orbit watching it land.
private struct DecideHomeCard: View {
    let model: DecideAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("Decide")
            HStack(spacing: 12) {
                OrbitView(size: 40, mood: model.heads == nil ? .normal : .happy,
                          motion: reduceMotion ? .still : (model.busy ? .working : .idle))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Flip here, or open for dice and lists").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                Spacer(minLength: 0)
                GlassPillButton(title: "Flip", symbol: "circle.lefthalf.filled") { model.flipCoin(reduceMotion: reduceMotion) }
            }
            Spacer(minLength: 0)
        }
    }

    private var headline: String {
        if model.busy, model.mode == .coin || model.heads == nil { return "Flipping…" }
        if let heads = model.heads { return heads ? "Heads!" : "Tails!" }
        if let chosen = model.chosen { return "Orbit picked \(chosen)" }
        return "Can't decide?"
    }
}

// MARK: - Views

private struct DecidePanel: View {
    @Bindable var model: DecideAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "dice.fill", title: "Decide", subtitle: subtitle, tint: .funTint)
                FunSegments(options: [(.coin, "Coin", "circle.lefthalf.filled"), (.dice, "Dice", "dice"), (.pick, "Pick one", "list.bullet")],
                            selection: $model.mode)
            }
            switch model.mode {
            case .coin: coin
            case .dice: dice
            case .pick: pick
            }
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .coin: "Heads or tails?"
        case .dice: "Roll for it."
        case .pick: "Can't choose? Let Orbit pick."
        }
    }

    // MARK: Coin

    private var coin: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            CoinView(angle: model.coinAngle)
                .frame(width: 150, height: 150)
                .onTapGesture { model.flipCoin(reduceMotion: reduceMotion) }
            Text(model.heads.map { $0 ? "Heads" : "Tails" } ?? (model.busy ? "Flipping…" : "Tap to flip"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.heads == nil ? Tokens.secondary : .white)
                .contentTransition(.opacity)
            PillButton(title: "Flip") { model.flipCoin(reduceMotion: reduceMotion) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }

    // MARK: Dice

    private var dice: some View {
        VStack(spacing: 16) {
            FunSegments(options: DecideLogic.Dice.allCases.map { ($0, $0.title, nil) }, selection: $model.dice)
                .padding(.top, 14)
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                OrbitView(size: 52, mood: model.busy ? .wide : .happy, motion: reduceMotion ? .still : (model.busy ? .working : .idle),
                          gaze: model.busy ? nil : CGVector(dx: 1, dy: 0.3))
                ForEach(Array(model.values.enumerated()), id: \.offset) { i, value in
                    DieView(value: value, sides: model.dice.sides)
                        .frame(width: 110, height: 110)
                        .rotationEffect(.degrees(model.wobble * (i.isMultiple(of: 2) ? 1 : -1)))
                }
            }
            .onTapGesture { model.rollDice(reduceMotion: reduceMotion) }
            Text(model.busy ? "Rolling…" : total)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tokens.secondary)
            PillButton(title: "Roll") { model.rollDice(reduceMotion: reduceMotion) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }

    private var total: String {
        model.values.count > 1 ? "Total \(model.values.reduce(0, +))" : "You rolled \(model.values.first ?? 0)"
    }

    // MARK: Pick one

    private var pick: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel("Your options")
                TextEditor(text: $model.list)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
                Text("Separate with commas or new lines.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.faint)
            }
            .padding(12)
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .glassCard(22)

            VStack(spacing: 12) {
                let items = model.options
                if items.isEmpty {
                    Spacer()
                    OrbitView(size: 56, motion: reduceMotion ? .still : .thinking)
                    Text("Type a few options and Orbit will pick one.").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
                    Spacer()
                } else {
                    Spacer(minLength: 0)
                    ZStack {
                        if let chosen = model.chosen {
                            VStack(spacing: 4) {
                                OrbitView(size: 44, mood: .happy, motion: reduceMotion ? .still : .celebrate)
                                Text(chosen)
                                    .font(.system(size: 26, weight: .bold))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        } else {
                            VStack(spacing: 4) {
                                OrbitView(size: 44, motion: reduceMotion ? .still : (model.busy ? .working : .thinking))
                                Text(model.highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil } ?? "?")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(model.busy ? .white : Tokens.faint)
                                    .lineLimit(1).minimumScaleFactor(0.5)
                            }
                        }
                    }
                    .frame(height: 96)
                    FlowChips(items: items, highlighted: model.highlighted)
                    Spacer(minLength: 0)
                    PillButton(title: model.chosen == nil ? "Pick one" : "Pick again") { model.pickOne(reduceMotion: reduceMotion) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(22)
        }
    }
}

/// A coin seen from the side as it turns; heads shows Orbit, tails a star.
private struct CoinView: View, Animatable {
    var angle: Double
    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showingHeads = cos(angle * .pi / 180) >= 0
        let squeeze = max(abs(cos(angle * .pi / 180)), 0.04)
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.45), Color(red: 0.86, green: 0.58, blue: 0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color(red: 1, green: 0.93, blue: 0.7).opacity(0.8), lineWidth: 5)
            Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1).padding(10)
            if showingHeads {
                VStack(spacing: 2) {
                    OrbitView(size: 64, motion: .still)
                    Text("HEADS").font(.system(size: 11, weight: .heavy)).tracking(1.5).foregroundStyle(.black.opacity(0.55))
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(.black.opacity(0.45))
                    Text("TAILS").font(.system(size: 11, weight: .heavy)).tracking(1.5).foregroundStyle(.black.opacity(0.55))
                }
            }
        }
        .scaleEffect(x: squeeze, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }
}

/// A die: pips for six sides, a gem-like shape with the number for a d20.
private struct DieView: View {
    let value: Int
    let sides: Int

    var body: some View {
        if sides == 6 {
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                let body = Path(roundedRect: rect, cornerRadius: size.width * 0.2, style: .continuous)
                ctx.fill(body, with: .linearGradient(Gradient(colors: [.white, Color(white: 0.82)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                let r = size.width * 0.075
                for p in DecideLogic.pips(value) {
                    let c = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(white: 0.12)))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
        } else {
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 2
                    var hex = Path()
                    for i in 0..<6 {
                        let a = Double(i) / 6 * 2 * .pi - .pi / 2
                        let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
                    }
                    hex.closeSubpath()
                    ctx.fill(hex, with: .linearGradient(Gradient(colors: [Color.funTint, Color(red: 0.55, green: 0.3, blue: 0.85)]),
                                                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                    // Facets: an inner triangle and lines to the corners.
                    var tri = Path()
                    let ir = r * 0.58
                    for i in 0..<3 {
                        let a = Double(i) / 3 * 2 * .pi - .pi / 2
                        let p = CGPoint(x: c.x + ir * cos(a), y: c.y + ir * sin(a))
                        if i == 0 { tri.move(to: p) } else { tri.addLine(to: p) }
                    }
                    tri.closeSubpath()
                    ctx.stroke(tri, with: .color(.white.opacity(0.35)), lineWidth: 1.2)
                    ctx.stroke(hex, with: .color(.white.opacity(0.45)), lineWidth: 1.5)
                }
                Text("\(value)").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .offset(y: 4)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
        }
    }
}

/// The options as small capsules that wrap onto new lines; the one being passed over lights up.
private struct FlowChips: View {
    let items: [String]
    let highlighted: Int?

    var body: some View {
        FunFlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Text(item)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(i == highlighted ? .black : Tokens.secondary)
                    .background(Capsule().fill(i == highlighted ? Color.white : Tokens.surface))
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FunFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let first = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += first ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
