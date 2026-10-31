import SwiftUI

/// Star Catcher, the game itself: no drawing, no clock. `step` moves it forward by `dt` seconds.
struct StarCatcherGame {
    enum Kind: Equatable { case star, meteor }
    enum Phase: Equatable { case ready, playing, paused, over }
    enum Event: Equatable { case caught, hit, gameOver }

    struct Item: Identifiable, Equatable {
        let id: Int
        var x: Double
        var y: Double
        let kind: Kind
        /// Radius in points.
        let size: Double
        var spin: Double = 0
    }

    struct Pop: Equatable {
        var x: Double, y: Double
        var age: Double = 0
        let good: Bool
    }

    var width = 600.0
    var height = 320.0
    var playerX = 300.0
    var playerY: Double { height - 30 }

    var items: [Item] = []
    var pops: [Pop] = []
    var score = 0
    var lives = 3
    var elapsed = 0.0
    var phase = Phase.ready
    var lastCatch = -10.0
    var lastHit = -10.0
    private var spawnIn = 0.4
    private var nextID = 0

    static let startLives = 3
    /// How close (points) a falling thing must be to the planet to count.
    static let reachX = 28.0
    static let reachY = 20.0
    static let playerSpeed = 420.0

    /// Points per second things fall; rises the longer you last.
    var fallSpeed: Double { min(95 + elapsed * 4.5, 340) }
    /// Seconds between new things.
    var spawnEvery: Double { max(0.3, 0.85 - elapsed * 0.012) }
    var meteorChance: Double { min(0.38, 0.14 + elapsed * 0.005) }

    mutating func start() {
        items = []; pops = []
        score = 0; lives = Self.startLives; elapsed = 0
        spawnIn = 0.4; lastCatch = -10; lastHit = -10
        playerX = width / 2
        phase = .playing
    }

    mutating func resize(width: Double, height: Double) {
        guard width > 40, height > 40 else { return }
        let sx = width / self.width, sy = height / self.height
        for i in items.indices { items[i].x *= sx; items[i].y *= sy }
        playerX *= sx
        self.width = width; self.height = height
        playerX = clampX(playerX)
    }

    func clampX(_ x: Double) -> Double { min(max(x, 22), width - 22) }

    /// Moves the planet: arrow keys win, otherwise it glides toward the mouse.
    mutating func movePlayer(dt: Double, keys: Int, target: Double?) {
        if keys != 0 {
            playerX = clampX(playerX + Double(keys) * Self.playerSpeed * dt)
        } else if let target {
            playerX = clampX(playerX + (target - playerX) * min(1, dt * 16))
        }
    }

    static func reaches(_ item: Item, playerX: Double, playerY: Double) -> Bool {
        abs(item.x - playerX) <= reachX + item.size * 0.5 && abs(item.y - playerY) <= reachY + item.size * 0.5
    }

    @discardableResult
    mutating func step<R: RandomNumberGenerator>(dt rawDT: Double, using rng: inout R) -> [Event] {
        for i in pops.indices { pops[i].age += rawDT }
        pops.removeAll { $0.age > 0.7 }
        guard phase == .playing else { return [] }
        let dt = min(max(rawDT, 0), 0.05)
        elapsed += dt
        var events: [Event] = []

        spawnIn -= dt
        if spawnIn <= 0 {
            spawnIn = spawnEvery * Double.random(in: 0.7...1.3, using: &rng)
            let meteor = Double.random(in: 0...1, using: &rng) < meteorChance
            items.append(Item(id: nextID, x: Double.random(in: 20...max(21, width - 20), using: &rng), y: -16,
                              kind: meteor ? .meteor : .star,
                              size: meteor ? Double.random(in: 9...13, using: &rng) : Double.random(in: 8...11, using: &rng)))
            nextID += 1
        }

        let speed = fallSpeed
        for i in items.indices {
            items[i].y += speed * dt * (items[i].kind == .meteor ? 1.2 : 1)
            items[i].spin += dt * (items[i].kind == .star ? 2 : 4)
        }

        var kept: [Item] = []
        for item in items {
            if Self.reaches(item, playerX: playerX, playerY: playerY) {
                pops.append(Pop(x: item.x, y: item.y, good: item.kind == .star))
                if item.kind == .star {
                    score += 1; lastCatch = elapsed; events.append(.caught)
                } else {
                    lives -= 1; lastHit = elapsed; events.append(.hit)
                }
            } else if item.y < height + 24 {
                kept.append(item)
            }
        }
        items = kept
        if lives <= 0 {
            lives = 0
            phase = .over
            events.append(.gameOver)
        }
        return events
    }
}

/// Notch Arcade: a tiny game of catching stars with Orbit.
@MainActor
@Observable
final class ArcadeAddOn: AddOnModule {
    let id = "addon.arcade"
    let title = "Arcade"
    let symbol = "gamecontroller.fill"
    let addOn = AddOnInfo(category: .fun, tier: .free,
                          summary: "Star Catcher: steer Orbit to catch falling stars and dodge meteors.")

    private struct Saved: Codable { var highScore: Int }

    var game = StarCatcherGame()
    private(set) var highScore: Int
    private(set) var newBest = false
    /// −1 left, 0 none, 1 right (from held arrow keys).
    var keys = 0
    private var held: Set<Int> = []
    var mouseX: Double?
    private var lastTick: Date?
    private var rng = SystemRandomNumberGenerator()
    private let openPanel: @MainActor (String) -> Void

    init(openPanel: @escaping @MainActor (String) -> Void = { _ in }) {
        self.openPanel = openPanel
        highScore = Storage.load(Saved.self, from: "addon-arcade")?.highScore ?? 0
    }

    func start() {}
    func stop() { pause() }

    func play() {
        game.start()
        newBest = false
        lastTick = nil
    }

    func pause() {
        if game.phase == .playing { game.phase = .paused }
        lastTick = nil
        held = []; keys = 0
    }

    func resume() {
        guard game.phase == .paused else { return }
        lastTick = nil
        game.phase = .playing
    }

    func key(_ direction: Int, down: Bool) {
        if down { held.insert(direction) } else { held.remove(direction) }
        keys = held.reduce(0, +)
        if down { mouseX = nil }
    }

    func tick(_ date: Date) {
        defer { lastTick = date }
        guard let last = lastTick else { return }
        let dt = date.timeIntervalSince(last)
        game.movePlayer(dt: min(dt, 0.05), keys: keys, target: mouseX)
        let events = game.step(dt: dt, using: &rng)
        if events.contains(.gameOver), game.score > highScore {
            highScore = game.score
            newBest = true
            Storage.save(Saved(highScore: highScore), to: "addon-arcade")
        }
    }

    var homeCard: AnyView? {
        AnyView(Button { self.openPanel(self.id) } label: { NotchCard { ArcadeHomeCard(model: self) } }.buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(ArcadePanel(model: self)) }
}

/// Home: Orbit eyeing a falling star, with your best score.
private struct ArcadeHomeCard: View {
    let model: ArcadeAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("Star Catcher")
            HStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                    // A star drifts down towards Orbit, over and over.
                    let t = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    ZStack {
                        ArcadeStar().frame(width: 12, height: 12)
                            .offset(x: 6, y: -24 + 24 * t)
                            .opacity(t < 0.8 ? 1 : (1 - t) * 5)
                        OrbitView(size: 36, mood: t > 0.8 ? .happy : .normal, motion: .still,
                                  gaze: CGVector(dx: 0.3, dy: -1 + 1.2 * t))
                            .offset(y: 8)
                    }
                    .frame(width: 46, height: 56)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.highScore > 0 ? "Best \(model.highScore)" : "Catch some stars")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.game.phase == .paused ? "Game paused · tap to carry on" : "Steer Orbit, dodge the meteors")
                        .font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, -6)
            Spacer(minLength: 0)
        }
    }
}

/// A small glowing star, as in the game.
private struct ArcadeStar: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.shadow(color: Color(red: 1, green: 0.85, blue: 0.3).opacity(0.9), radius: 3))
            ctx.fill(ArcadeDrawing.starPath(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.width / 2, angle: 0),
                     with: .color(Color(red: 1, green: 0.88, blue: 0.4)))
        }
    }
}

// MARK: - Views

private struct ArcadePanel: View {
    @Bindable var model: ArcadeAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "gamecontroller.fill", title: "Star Catcher",
                            subtitle: "Catch the stars, dodge the meteors.", tint: .funTint)
                HStack(spacing: 5) {
                    Image(systemName: "trophy.fill").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                    Text("Best \(model.highScore)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassSurface(Capsule())
            }
            field
        }
        .onDisappear { model.pause() }
    }

    private var field: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: model.game.phase != .playing)) { timeline in
                    let snapshot = model.game
                    Canvas { ctx, size in ArcadeDrawing.draw(&ctx, size: size, game: snapshot, time: timeline.date.timeIntervalSinceReferenceDate) }
                        .onChange(of: timeline.date) { _, date in model.tick(date) }
                }

                OrbitView(size: 46, mood: mood, motion: .still)
                    .position(x: model.game.playerX, y: model.game.playerY)
                    .opacity(model.game.phase == .ready ? 0.0 : 1)

                hud
                overlay.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { model.game.resize(width: geo.size.width, height: geo.size.height) }
            .onChange(of: geo.size) { _, size in model.game.resize(width: size.width, height: size.height) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassCard(22)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase, model.game.phase == .playing { model.mouseX = p.x }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .up]) { press in
            let direction = press.key == .leftArrow ? -1 : 1
            model.key(direction, down: press.phase != .up)
            return .handled
        }
        .onKeyPress(.space) {
            switch model.game.phase {
            case .ready, .over: model.play()
            case .playing: model.pause()
            case .paused: model.resume()
            }
            return .handled
        }
        .onAppear { focused = true }
    }

    private var mood: OrbitView.Mood {
        let g = model.game
        if g.phase == .over { return .closed }
        if g.elapsed - g.lastHit < 0.6 { return .grumpy }
        if g.elapsed - g.lastCatch < 0.35 { return .happy }
        return .normal
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Text("\(model.game.score)")
                .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 3) {
                ForEach(0..<StarCatcherGame.startLives, id: \.self) { i in
                    Image(systemName: i < model.game.lives ? "heart.fill" : "heart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(i < model.game.lives ? Tokens.error : Tokens.faint)
                }
            }
            Spacer()
            if model.game.phase == .playing {
                Button { model.pause() } label: {
                    Image(systemName: "pause.fill").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).glassSurface(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Pause (space)")
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .opacity(model.game.phase == .ready ? 0 : 1)
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.game.phase {
        case .ready:
            VStack(spacing: 10) {
                OrbitView(size: 64, mood: .happy, motion: reduceMotion ? .still : .idle)
                Text("Star Catcher").font(.system(size: 20, weight: .bold))
                Text("Move Orbit with the mouse or ← →. Stars score, meteors cost a life.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
                PillButton(title: "Start") { model.play(); focused = true }.padding(.top, 4)
            }
        case .paused:
            VStack(spacing: 10) {
                Text("Paused").font(.system(size: 20, weight: .bold))
                PillButton(title: "Resume") { model.resume(); focused = true }
            }
            .padding(24).glassCard(22)
        case .over:
            VStack(spacing: 8) {
                Text(model.newBest ? "New best!" : "Game over").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(model.newBest ? Tokens.attention : .white)
                Text("You caught \(model.game.score) \(model.game.score == 1 ? "star" : "stars").")
                    .font(.system(size: 13)).foregroundStyle(Tokens.secondary)
                PillButton(title: "Play again") { model.play(); focused = true }.padding(.top, 4)
            }
            .padding(24).glassCard(22)
        case .playing:
            EmptyView()
        }
    }
}

/// Draws the sky, falling stars, meteors and little bursts.
private enum ArcadeDrawing {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, game: StarCatcherGame, time: Double) {
        let bounds = CGRect(origin: .zero, size: size)
        ctx.fill(Path(bounds), with: .linearGradient(
            Gradient(colors: [Color(red: 0.04, green: 0.03, blue: 0.12).opacity(0.85), Color(red: 0.13, green: 0.07, blue: 0.24).opacity(0.85)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // Far-away stars that twinkle a little.
        for i in 0..<46 {
            let x = hash(Double(i) * 3.1) * size.width, y = hash(Double(i) * 7.7 + 1) * size.height
            let twinkle = 0.35 + 0.35 * sin(time * (0.8 + hash(Double(i)) * 1.6) + Double(i))
            let r = 0.6 + hash(Double(i) + 5) * 0.9
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(twinkle)))
        }
        // A soft glow along the ground.
        ctx.fill(Path(CGRect(x: 0, y: size.height - 50, width: size.width, height: 50)),
                 with: .linearGradient(Gradient(colors: [.clear, Color.funTint.opacity(0.18)]),
                                       startPoint: CGPoint(x: 0, y: size.height - 50), endPoint: CGPoint(x: 0, y: size.height)))

        var items = game.items
        if game.phase == .ready {
            // A few stars hanging in the sky before the game starts.
            items = [(0.12, 0.28, 0), (0.18, 0.72, 1), (0.84, 0.2, 0), (0.9, 0.6, 0), (0.76, 0.86, 1), (0.3, 0.12, 0)].enumerated().map { i, s in
                StarCatcherGame.Item(id: i, x: s.0 * size.width, y: s.1 * size.height, kind: s.2 == 1 ? .meteor : .star, size: 10, spin: Double(i))
            }
        }

        for item in items where item.kind == .meteor {
            let tail = Path { p in
                p.move(to: CGPoint(x: item.x - item.size * 0.8, y: item.y))
                p.addLine(to: CGPoint(x: item.x, y: item.y - item.size * 4.2))
                p.addLine(to: CGPoint(x: item.x + item.size * 0.8, y: item.y))
                p.closeSubpath()
            }
            ctx.fill(tail, with: .linearGradient(Gradient(colors: [Color.orange.opacity(0.55), .clear]),
                                                 startPoint: CGPoint(x: item.x, y: item.y), endPoint: CGPoint(x: item.x, y: item.y - item.size * 4.2)))
            let rock = CGRect(x: item.x - item.size, y: item.y - item.size, width: item.size * 2, height: item.size * 2)
            ctx.fill(Path(ellipseIn: rock), with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.55, blue: 0.3), Color(red: 0.55, green: 0.2, blue: 0.15)]),
                                                                  center: CGPoint(x: item.x - item.size * 0.3, y: item.y - item.size * 0.3),
                                                                  startRadius: 0, endRadius: item.size * 1.4))
            let crater = item.size * 0.28
            ctx.fill(Path(ellipseIn: CGRect(x: item.x + item.size * 0.15, y: item.y + item.size * 0.05, width: crater * 2, height: crater * 2)),
                     with: .color(.black.opacity(0.25)))
        }

        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color(red: 1, green: 0.85, blue: 0.3).opacity(0.9), radius: 6))
            for item in items where item.kind == .star {
                layer.fill(starPath(center: CGPoint(x: item.x, y: item.y), radius: item.size, angle: item.spin),
                           with: .color(Color(red: 1, green: 0.88, blue: 0.4)))
            }
        }

        for pop in game.pops {
            let t = pop.age / 0.7
            let r = 8 + t * 22
            ctx.stroke(Path(ellipseIn: CGRect(x: pop.x - r, y: pop.y - r, width: r * 2, height: r * 2)),
                       with: .color((pop.good ? Color(red: 1, green: 0.88, blue: 0.4) : Tokens.error).opacity(1 - t)), lineWidth: 2)
            ctx.draw(Text(pop.good ? "+1" : "−1").font(.system(size: 13, weight: .bold)).foregroundStyle(pop.good ? Color.white : Tokens.error),
                     at: CGPoint(x: pop.x, y: pop.y - 18 - t * 20))
        }
    }

    static func starPath(center: CGPoint, radius: Double, angle: Double) -> Path {
        Path { p in
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? radius : radius * 0.45
                let a = angle + Double(i) / 10 * 2 * .pi - .pi / 2
                let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }

    static func hash(_ n: Double) -> Double {
        let x = sin(n * 12.9898) * 43758.5453
        return x - floor(x)
    }
}
