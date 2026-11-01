import SwiftUI

// Orbit acting out the weather: sunglasses in the sun, an umbrella in the rain, a bobble hat in the snow…

extension WeatherLogic {
    /// What Orbit acts out for a weather code.
    enum Scene: String, CaseIterable, Equatable {
        case sunny, partly, cloudy, fog, rain, snow, thunder, night

        /// A few words about what Orbit is up to (also read out by VoiceOver).
        var line: String {
            switch self {
            case .sunny: "Sunglasses on"
            case .partly: "Watching the sun play hide and seek"
            case .cloudy: "Clouds drifting by"
            case .fog: "Squinting through the fog"
            case .rain: "Umbrella weather"
            case .snow: "Bobble hat weather"
            case .thunder: "Eek, thunder!"
            case .night: "Asleep under the moon"
            }
        }

        /// Orbit's eyes and how it moves in this weather.
        var mood: OrbitView.Mood {
            switch self {
            case .sunny: .happy
            case .partly, .cloudy, .rain: .normal
            case .fog, .snow: .squint
            case .thunder: .wide
            case .night: .closed
            }
        }

        var motion: OrbitView.Motion {
            switch self {
            case .sunny: .glow
            case .night: .sleep
            default: .idle
            }
        }
    }

    /// Clear and partly cloudy nights put Orbit to sleep; otherwise the sky decides.
    static func scene(_ code: Int, isDay: Bool) -> Scene {
        switch sky(code) {
        case .clear: isDay ? .sunny : .night
        case .partly: isDay ? .partly : .night
        case .cloudy: .cloudy
        case .fog: .fog
        case .drizzle, .rain: .rain
        case .snow: .snow
        case .thunder: .thunder
        }
    }
}

/// Orbit in the weather, with its props. With `sky`, it also paints the sky behind (the panel's big picture);
/// without, it's just Orbit and the weather around it (Home card).
struct WeatherOrbitScene: View {
    let code: Int
    let isDay: Bool
    var orbitSize: CGFloat = 46
    var sky = false
    /// Where Orbit's middle sits, as a fraction of the frame.
    var anchor = UnitPoint(x: 0.5, y: 0.6)
    var fps: Double = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scene: WeatherLogic.Scene { WeatherLogic.scene(code, isDay: isDay) }

    /// On Home the weather fades out softly at the edges instead of stopping at a hard line.
    private var edgeFade: some View {
        Group {
            if sky { Color.black } else {
                EllipticalGradient(stops: [.init(color: .black, location: 0.62), .init(color: .clear, location: 1)])
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1 / fps, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let stage = WeatherStage(size: geo.size, orbitSize: orbitSize, anchor: anchor, t: t,
                                         scene: scene, intensity: WeatherLogic.intensity(code), still: reduceMotion)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        if sky { WeatherSky.paint(&ctx, size: size, t: t, code: code, isDay: isDay, backdrop: true) }
                        stage.back(&ctx)
                    }
                    .mask(edgeFade)
                    OrbitView(size: orbitSize, mood: scene.mood, motion: reduceMotion ? .still : scene.motion,
                              tint: Color(red: 1, green: 0.82, blue: 0.35), gaze: stage.gaze)
                        .offset(x: stage.origin.x + stage.dx, y: stage.origin.y)
                    Canvas { ctx, size in
                        stage.front(&ctx)
                        if sky, scene == .thunder, let flash = stage.flash {
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.3 * flash)))
                        }
                    }
                    .mask(edgeFade)
                }
            }
        }
        // One layer, so shadows from the panel fall around the scene, not from the props onto Orbit.
        .compositingGroup()
        .accessibilityElement()
        .accessibilityLabel("Orbit: \(scene.line)")
    }
}

/// Where everything is at one moment, and the drawing of the props.
/// Orbit's own drawing is a 104-unit square (body r30 at 52,54); `p` maps those units into the frame.
private struct WeatherStage {
    let size: CGSize
    let orbitSize: CGFloat
    let anchor: UnitPoint
    let t: Double
    let scene: WeatherLogic.Scene
    let intensity: Double
    let still: Bool

    var u: CGFloat { orbitSize / 104 }
    /// Orbit's frame, top-left.
    var origin: CGPoint {
        CGPoint(x: size.width * anchor.x - orbitSize / 2, y: size.height * anchor.y - orbitSize / 2)
    }

    /// The same little float Orbit does on its own, so things it wears move with it.
    var hop: Double {
        if still { return 0 }
        switch scene.motion {
        case .idle: return 1.4 * sin(t * 2 * .pi / 3.4)
        case .glow: return 1 * sin(t * 2 * .pi / 3.4)
        case .sleep: return 1 * sin(t * 2 * .pi / 4.5)
        default: return 0
        }
    }

    /// Sideways jolt: a shiver in the snow, a flinch at thunder.
    var dx: CGFloat {
        if still { return 0 }
        switch scene {
        case .snow:
            let c = t.truncatingRemainder(dividingBy: 3.2)
            return c < 0.6 ? 1.6 * u * sin(c * 70) * (1 - c / 0.6) : 0
        case .thunder:
            guard let f = flash else { return 0 }
            return 2.4 * u * sin(t * 80) * f
        default: return 0
        }
    }

    /// 0…1 while lightning flashes, nil otherwise.
    var flash: Double? {
        guard scene == .thunder, !still else { return nil }
        let c = t.truncatingRemainder(dividingBy: 3.6)
        return c < 0.45 ? 1 - c / 0.45 : nil
    }

    var gaze: CGVector? {
        switch scene {
        case .sunny, .night: return nil
        case .partly: return CGVector(dx: -0.7, dy: -0.8)
        case .cloudy: return CGVector(dx: still ? 0.6 : sin(t * 0.3) * 0.9, dy: 0.4)
        case .fog: return CGVector(dx: still ? 0.5 : sin(t * 0.6), dy: 0)
        case .rain: return CGVector(dx: -0.2, dy: -0.7)
        case .snow: return CGVector(dx: 0.3, dy: -0.3)
        case .thunder: return CGVector(dx: -0.6, dy: -0.9)
        }
    }

    /// A point in Orbit's units, moving with Orbit.
    func p(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + dx + (x + 2) * u, y: origin.y + (y + 2 - hop) * u)
    }

    /// A point in Orbit's units that stays put (sun, clouds, umbrella).
    func fixed(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + (x + 2) * u, y: origin.y + (y + 2) * u)
    }

    // MARK: Behind Orbit

    func back(_ ctx: inout GraphicsContext) {
        switch scene {
        case .sunny:
            sun(&ctx, at: fixed(4, 2), r: 14, rays: true)
        case .partly:
            sun(&ctx, at: fixed(6, 4), r: 12, rays: false)
            let drift = still ? 0 : 9 * sin(t * 0.35)
            cloud(&ctx, at: fixed(14 + drift, 14), scale: 0.42, color: .white.opacity(0.92))
        case .cloudy:
            let drift = still ? 0 : 6 * sin(t * 0.22 + 1)
            cloud(&ctx, at: fixed(84 + drift, 4), scale: 0.5, color: Color(white: 0.85).opacity(0.85))
            cloud(&ctx, at: fixed(12 - drift, 16), scale: 0.36, color: Color(white: 0.75).opacity(0.7))
        case .rain:
            umbrella(&ctx, handle: true)
        case .thunder:
            cloud(&ctx, at: fixed(30, 2), scale: 0.62, color: Color(red: 0.33, green: 0.35, blue: 0.42))
            if let f = flash ?? (still ? 1 : nil) { bolt(&ctx, from: fixed(22, 14), alpha: still ? 0.9 : f) }
        case .night:
            moon(&ctx, at: fixed(4, 4), r: 12)
            let spots: [(Double, Double)] = [(-22, -10), (30, -18), (-14, 30), (40, 2), (22, -30)]
            for (i, spot) in spots.enumerated() {
                let s = fixed(spot.0, spot.1)
                let a = still ? 0.7 : 0.35 + 0.45 * (0.5 + 0.5 * sin(t * (1 + hash(Double(i))) + Double(i)))
                sparkle(&ctx, at: s, r: (1.6 + hash(Double(i) + 2) * 1.6) * u, alpha: a)
            }
        case .fog, .snow:
            break
        }
    }

    // MARK: In front of Orbit

    func front(_ ctx: inout GraphicsContext) {
        switch scene {
        case .sunny:
            sunglasses(&ctx)
        case .cloudy:
            let x = still ? 30 : 34 + 34 * sin(t * 0.3)
            cloud(&ctx, at: fixed(x, 88), scale: 0.38, color: .white.opacity(0.9))
        case .fog:
            var ctx = ctx
            ctx.addFilter(.blur(radius: 2.5 * u))
            for i in 0..<3 {
                let shift = still ? 0 : sin(t * 0.4 + Double(i) * 2) * 14
                let y = fixed(0, 36 + Double(i) * 20).y
                let rect = CGRect(x: -20 + shift * u, y: y, width: size.width + 40, height: 8 * u)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4 * u), with: .color(.white.opacity(0.2 + 0.06 * Double(i))))
            }
        case .rain:
            rain(&ctx, sheltered: true)
            umbrella(&ctx, handle: false)
        case .thunder:
            rain(&ctx, sheltered: false)
        case .snow:
            hat(&ctx)
            snow(&ctx)
        case .night:
            zzz(&ctx)
        case .partly:
            break
        }
    }

    // MARK: Props

    private func sun(_ ctx: inout GraphicsContext, at c: CGPoint, r: Double, rays: Bool) {
        let pulse = still ? 1 : 1 + 0.05 * sin(t * 1.4)
        let gold = Color(red: 1, green: 0.85, blue: 0.35)
        for (k, a) in [(2.1, 0.12), (1.55, 0.2)] {
            let rr = r * k * pulse * u
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(gold.opacity(a)))
        }
        if rays {
            var path = Path()
            for i in 0..<10 {
                let a = Double(i) / 10 * 2 * .pi + (still ? 0 : t * 0.25)
                path.move(to: CGPoint(x: c.x + (r + 5) * u * cos(a), y: c.y + (r + 5) * u * sin(a)))
                path.addLine(to: CGPoint(x: c.x + (r + 10) * u * cos(a), y: c.y + (r + 10) * u * sin(a)))
            }
            ctx.stroke(path, with: .color(gold.opacity(0.8)), style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * u, y: c.y - r * u, width: 2 * r * u, height: 2 * r * u)), with: .color(gold))
    }

    private func moon(_ ctx: inout GraphicsContext, at c: CGPoint, r: Double) {
        let rr = r * u
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr * 2, y: c.y - rr * 2, width: rr * 4, height: rr * 4)),
                 with: .color(Color(red: 0.85, green: 0.88, blue: 1).opacity(0.1)))
        var m = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        m = m.subtracting(Path(ellipseIn: CGRect(x: c.x - rr * 0.45, y: c.y - rr * 1.35, width: rr * 2, height: rr * 2)))
        ctx.fill(m, with: .color(Color(red: 0.97, green: 0.95, blue: 0.84)))
    }

    private func sparkle(_ ctx: inout GraphicsContext, at c: CGPoint, r: CGFloat, alpha: Double) {
        var s = Path()
        s.move(to: CGPoint(x: c.x, y: c.y - r)); s.addLine(to: CGPoint(x: c.x, y: c.y + r))
        s.move(to: CGPoint(x: c.x - r, y: c.y)); s.addLine(to: CGPoint(x: c.x + r, y: c.y))
        ctx.stroke(s, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: max(r * 0.45, 0.8), lineCap: .round))
    }

    /// A puffy cloud; `scale` 1 is about 92 units wide.
    private func cloud(_ ctx: inout GraphicsContext, at c: CGPoint, scale s: Double, color: Color) {
        let k = s * u
        var path = Path()
        for (dx, dy, r) in [(-30.0, 6.0, 18.0), (-8, -8, 24), (18, -2, 20), (36, 8, 14)] {
            path.addEllipse(in: CGRect(x: c.x + (dx - r) * k, y: c.y + (dy - r) * k, width: 2 * r * k, height: 2 * r * k))
        }
        path.addRoundedRect(in: CGRect(x: c.x - 44 * k, y: c.y + 2 * k, width: 92 * k, height: 20 * k),
                            cornerSize: CGSize(width: 10 * k, height: 10 * k))
        ctx.fill(path, with: .color(color))
    }

    private func bolt(_ ctx: inout GraphicsContext, from top: CGPoint, alpha: Double) {
        var b = Path()
        b.move(to: top)
        b.addLine(to: CGPoint(x: top.x - 7 * u, y: top.y + 15 * u))
        b.addLine(to: CGPoint(x: top.x + 1 * u, y: top.y + 15 * u))
        b.addLine(to: CGPoint(x: top.x - 6 * u, y: top.y + 31 * u))
        b.addLine(to: CGPoint(x: top.x + 9 * u, y: top.y + 10 * u))
        b.addLine(to: CGPoint(x: top.x + 1 * u, y: top.y + 10 * u))
        b.addLine(to: CGPoint(x: top.x + 6 * u, y: top.y))
        b.closeSubpath()
        var glow = ctx
        glow.addFilter(.shadow(color: Color(red: 1, green: 0.9, blue: 0.4).opacity(alpha), radius: 5 * u))
        glow.fill(b, with: .color(Color(red: 1, green: 0.93, blue: 0.55).opacity(alpha)))
    }

    private func sunglasses(_ ctx: inout GraphicsContext) {
        let frame = Color(white: 0.08)
        let eyes = [p(54, 41), p(68, 49)]
        let angle = Angle.degrees(24)
        for e in eyes {
            var g = ctx
            g.translateBy(x: e.x, y: e.y)
            g.rotate(by: angle)
            let lens = Path(roundedRect: CGRect(x: -7 * u, y: -5.6 * u, width: 14 * u, height: 11.5 * u),
                            cornerSize: CGSize(width: 4.5 * u, height: 5 * u), style: .continuous)
            g.fill(lens, with: .color(frame))
            // A little shine.
            var shine = Path()
            shine.move(to: CGPoint(x: -3.8 * u, y: -1 * u)); shine.addLine(to: CGPoint(x: -1 * u, y: -3.6 * u))
            g.stroke(shine, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round))
        }
        // Bridge between the lenses and an arm round the side.
        var bridge = Path()
        bridge.move(to: p(59.5, 44.5))
        bridge.addQuadCurve(to: p(63, 46.2), control: p(61.8, 43.4))
        bridge.move(to: p(74, 52)); bridge.addLine(to: p(80.5, 56))
        ctx.stroke(bridge, with: .color(frame), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
    }

    /// The handle goes behind Orbit (as if it holds it with its ring); the canopy goes over the rain.
    private func umbrella(_ ctx: inout GraphicsContext, handle: Bool) {
        let red = Color(red: 1, green: 0.42, blue: 0.47), dark = Color(red: 0.84, green: 0.27, blue: 0.36)
        var g = ctx
        let pivot = fixed(46, 30)
        g.translateBy(x: pivot.x, y: pivot.y)
        g.rotate(by: .degrees(-8))
        g.translateBy(x: -pivot.x, y: -pivot.y)
        let apex = fixed(46, -30), rim = -2.0, w = 50.0
        if handle {
            var stick = Path()
            stick.move(to: apex); stick.addLine(to: fixed(46, 34))
            g.stroke(stick, with: .color(Color(white: 0.85)), style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round))
            return
        }
        // Canopy: a dome with a scalloped edge, in alternating panels.
        let points = 4
        var canopy = Path()
        canopy.move(to: fixed(46 - w, rim))
        canopy.addCurve(to: apex, control1: fixed(46 - w, rim - 18), control2: fixed(46 - w * 0.55, -30))
        canopy.addCurve(to: fixed(46 + w, rim), control1: fixed(46 + w * 0.55, -30), control2: fixed(46 + w, rim - 18))
        let step = 2 * w / Double(points)
        for i in 0..<points {
            let x1 = 46 + w - step * Double(i), x2 = x1 - step
            canopy.addQuadCurve(to: fixed(x2, rim), control: fixed((x1 + x2) / 2, rim - 7))
        }
        canopy.closeSubpath()
        g.fill(canopy, with: .color(red))
        // Darker middle panels.
        var g2 = g
        g2.clip(to: canopy)
        for i in [1, 3] {
            let x1 = 46 + w - step * Double(i), x2 = x1 - step
            var panel = Path()
            panel.move(to: apex)
            panel.addLine(to: fixed(x1, rim + 2)); panel.addLine(to: fixed(x2, rim + 2))
            panel.closeSubpath()
            g2.fill(panel, with: .color(dark))
        }
        g.stroke(Path { $0.move(to: apex); $0.addLine(to: CGPoint(x: apex.x, y: apex.y - 6 * u)) },
                 with: .color(Color(white: 0.85)), style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round))
    }

    /// True under the umbrella's rim, where no rain falls (the canopy itself is drawn over the rain).
    private func underUmbrella(_ x: CGFloat, _ y: CGFloat) -> Bool {
        let dx = (x - origin.x) / u - 2
        guard dx > -4, dx < 95 else { return false }
        // The rim, tilted 8° like the umbrella.
        return y > fixed(0, -2 - 0.14 * (dx - 46)).y
    }

    private func rain(_ ctx: inout GraphicsContext, sheltered: Bool) {
        let area = size.width * size.height
        let count = Int(min(160, area / 650 * (0.5 + max(intensity, 0.35))))
        let len = (intensity < 0.5 ? 5.0 : 8.0) * max(u, 0.7)
        var drops = Path()
        for i in 0..<count {
            let x = hash(Double(i) * 1.7) * (size.width + 20) - 10
            let speed = (still ? 0 : 1) * (size.height * 1.4 + hash(Double(i) + 9) * size.height * 0.6)
            let y = (hash(Double(i) * 3.3) * size.height + t * speed).truncatingRemainder(dividingBy: size.height + 20) - 10
            if sheltered, underUmbrella(x, y + len) { continue }
            drops.move(to: CGPoint(x: x, y: y))
            drops.addLine(to: CGPoint(x: x - len * 0.2, y: y + len))
        }
        ctx.stroke(drops, with: .color(Color(red: 0.72, green: 0.84, blue: 1).opacity(0.7)),
                   style: StrokeStyle(lineWidth: max(1.2 * u, 1), lineCap: .round))
    }

    private func snow(_ ctx: inout GraphicsContext) {
        let area = size.width * size.height
        let count = Int(min(110, area / 800 * (0.6 + max(intensity, 0.35))))
        for i in 0..<count {
            let speed = still ? 0 : size.height * (0.12 + hash(Double(i) + 2) * 0.12)
            let y = (hash(Double(i) * 4.1) * size.height + t * speed).truncatingRemainder(dividingBy: size.height + 8) - 4
            let x = hash(Double(i) * 1.3) * size.width + (still ? 0 : sin(t * 0.9 + Double(i)) * 5 * u)
            let r = (1.1 + hash(Double(i) + 7) * 1.4) * max(u, 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.85)))
        }
    }

    /// A bobble hat, worn at the same jaunty angle as Orbit's eyes.
    private func hat(_ ctx: inout GraphicsContext) {
        var g = ctx
        let pivot = p(50, 52)
        g.translateBy(x: pivot.x, y: pivot.y)
        g.rotate(by: .degrees(14))
        g.translateBy(x: -pivot.x, y: -pivot.y)
        let wool = Color(red: 0.96, green: 0.36, blue: 0.42), cream = Color(red: 1, green: 0.95, blue: 0.9)
        var dome = Path()
        dome.move(to: p(27, 29))
        dome.addCurve(to: p(73, 29), control1: p(27, 3), control2: p(73, 3))
        dome.closeSubpath()
        g.fill(dome, with: .color(wool))
        // Knit lines.
        var knit = Path()
        for x in [38.0, 50, 62] {
            knit.move(to: p(x, 27)); knit.addQuadCurve(to: p(50 + (x - 50) * 0.4, 12), control: p(50 + (x - 50) * 0.9, 17))
        }
        g.stroke(knit, with: .color(Color(red: 0.82, green: 0.26, blue: 0.33)), lineWidth: 1.2 * u)
        let brim = Path(roundedRect: CGRect(x: p(24, 25).x, y: p(24, 25).y, width: 52 * u, height: 9 * u),
                        cornerSize: CGSize(width: 4.5 * u, height: 4.5 * u), style: .continuous)
        g.fill(brim, with: .color(cream))
        var ribs = Path()
        for i in 0..<9 {
            let x = 28 + Double(i) * 5.5
            ribs.move(to: p(x, 26.5)); ribs.addLine(to: p(x, 32.5))
        }
        g.stroke(ribs, with: .color(Color(red: 0.88, green: 0.82, blue: 0.76)), lineWidth: 1 * u)
        let ball = p(50, 6)
        g.fill(Path(ellipseIn: CGRect(x: ball.x - 6.5 * u, y: ball.y - 6.5 * u, width: 13 * u, height: 13 * u)), with: .color(cream))
    }

    private func zzz(_ ctx: inout GraphicsContext) {
        for i in 0..<3 {
            let phase = still ? Double(i) / 3 : ((t / 3.6) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let at = fixed(80 + phase * 18, 24 - phase * 38)
            let alpha = still ? 0.8 : min(phase * 4, 1) * (1 - phase)
            let fontSize = (8 + phase * 9) * u
            ctx.draw(Text("z").font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(alpha)), at: at)
        }
    }

    private func hash(_ n: Double) -> Double {
        let x = sin(n * 12.9898) * 43758.5453
        return x - floor(x)
    }
}
