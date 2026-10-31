import SwiftUI

/// Orbit, the companion: a little ringed planet with two tilted eyes.
///
/// Drawn in one Canvas from a 100×100 design (body r30 at 50,52, ring 94×30 tilted 24°).
/// Everything moves from the clock, so many Orbits on screen stay cheap and in step.
struct OrbitView: View {
    enum Mood: String, CaseIterable { case normal, wide, squint, grumpy, happy, closed, wink }

    /// What Orbit is doing. Each one uses the eyes, the ring and colour in its own way.
    enum Motion: String, CaseIterable {
        case still      // no movement at all (icons, settings)
        case idle       // blinks, floats, glances around, winks now and then
        case working    // ring swings, eyes scan left and right
        case thinking   // a moon circles the ring, eyes look up
        case listening  // ring pulses like a sound wave, eyes wide
        case nudge      // hops and squashes, ring wobbles, glows in the tint colour
        case celebrate  // ring cycles through the rainbow, happy hop and spin
        case alert      // body flashes the tint colour, ring shakes
        case sleep      // eyes closed, ring breathes dim and bright
        case glow       // calm, ring glows softly in the tint colour
    }

    var size: CGFloat = 20
    var mood: Mood = .normal
    var motion: Motion = .idle
    /// Signal colour for nudge, alert and glow (amber "needs you", red error…).
    var tint: Color = Tokens.attention
    /// Colours; nil = the one picked in Settings → Appearance.
    var colors: Appearance.Companion? = nil
    /// Where to look (x, y up to ±1). nil = Orbit decides.
    var gaze: CGVector? = nil
    /// Snapshots only: draw Orbit as it looks at this moment (seconds) instead of now.
    var time: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each Orbit runs on its own clock, so several on screen never move in step.
    @State private var seed = Double.random(in: 0..<600)

    var body: some View {
        let theme = colors ?? Appearance.shared.companion
        let calm = motion == .still || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: calm && motion == .still)) { timeline in
            let t = time ?? (timeline.date.timeIntervalSinceReferenceDate + seed)
            let pose = Pose.make(t: t, mood: mood, motion: calm ? .still : motion, blinks: motion != .still, gaze: gaze)
            Canvas { ctx, canvas in
                Self.draw(&ctx, canvas: canvas, pose: pose, theme: theme, tint: tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Orbit")
    }

    // MARK: Pose: everything that moves, worked out from the time

    struct Pose {
        var hop = 0.0, squashX = 1.0, squashY = 1.0, lean = 0.0
        var swing = 0.0, ringScale = 1.0, ringOpacity = 1.0, shake = 0.0
        var rainbow: Double? = nil      // hue 0…1 when the ring cycles colours
        var glow = 0.0                  // 0…1 ring glow in the tint colour
        var flash = 0.0                 // 0…1 body tinted with the tint colour
        var moon: Double? = nil         // angle of the little moon on the ring
        var eyes: Mood = .normal
        var open = 1.0                  // 1 open, 0 shut (blink)
        var look = CGVector.zero
        /// How far the planet has turned on its tilted axis (radians); the face goes round with it.
        var spin = 0.0
        /// Sideways drift.
        var sway = 0.0
        /// Each eye's width and height (1 = normal), so they can squint, shrink or go uneven.
        var eyeW = (1.0, 1.0), eyeH = (1.0, 1.0)
        /// Eyes stretch sideways while they dart (0 = still).
        var dart = 0.0

        static func make(t: Double, mood: Mood, motion: Motion, blinks: Bool, gaze: CGVector?) -> Pose {
            var p = Pose()
            p.eyes = mood
            if blinks { p.open = blink(t) }

            switch motion {
            case .still:
                break
            case .idle:
                p.hop = 1.4 * sin(t * 2 * .pi / 3.4)
                p.squashY = 1 + 0.02 * sin(t * 2 * .pi / 3.4 + 1)
                if mood == .normal { p.express(Beat.at(t, set: .idle)) }
            case .working:
                // Busy: reads with its eyes, then every few seconds spins right round on its axis
                // with a hop, lands with a squash, and keeps swaying a little.
                let cycle = 4.2, c = t.truncatingRemainder(dividingBy: cycle)
                let turn = 1.25
                if c < turn {
                    let k = c / turn
                    p.spin = 2 * .pi * ease(ease(k))
                    p.hop = 7 * sin(k * .pi)
                    p.squashY = 1 + 0.08 * sin(k * .pi)
                    p.squashX = 1 - 0.06 * sin(k * .pi)
                    p.swing = 10 * sin(k * 2 * .pi)
                } else {
                    let land = bump(c, turn, turn + 0.22)
                    p.squashX = 1 + 0.14 * land
                    p.squashY = 1 - 0.14 * land
                    p.hop = 1.5 * sin(t * 2 * .pi / 0.9)
                    p.swing = 6 * sin(t * 2 * .pi / 2.4)
                    if mood == .normal || mood == .squint { p.express(Beat.at(t, set: .working)) }
                    else { p.look = CGVector(dx: sin(t * 2 * .pi / 2.4), dy: 0.15) }
                }
                p.sway = 2.5 * sin(t * 2 * .pi / 3.1)
            case .thinking:
                p.moon = t * 2.4
                p.look = CGVector(dx: 0.35, dy: -0.8)
                if mood == .normal { p.eyes = .squint }
                p.swing = 4 * sin(t * 1.3)
            case .listening:
                let beat = 0.5 + 0.5 * sin(t * 2 * .pi / 0.9)
                p.ringScale = 1 + 0.07 * beat
                p.ringOpacity = 0.7 + 0.3 * beat
                if mood == .normal { p.eyes = .wide }
            case .nudge:
                // Two quick hops, then a pause; ring wobbles and glows.
                let c = t.truncatingRemainder(dividingBy: 1.6)
                let h1 = bump(c, 0, 0.32), h2 = bump(c, 0.36, 0.62)
                p.hop = 11 * h1 + 6 * h2
                let land = bump(c, 0.3, 0.4) + bump(c, 0.6, 0.7)
                p.squashX = 1 + 0.18 * land - 0.1 * (h1 + h2)
                p.squashY = 1 - 0.18 * land + 0.12 * (h1 + h2)
                p.swing = 9 * sin(t * 2 * .pi / 0.8)
                p.glow = 0.55 + 0.45 * sin(t * 2 * .pi / 0.8)
                if mood == .normal { p.eyes = .wide }
            case .celebrate:
                p.rainbow = (t * 0.45).truncatingRemainder(dividingBy: 1)
                let c = t.truncatingRemainder(dividingBy: 2.2)
                p.hop = 10 * bump(c, 0, 0.45)
                p.lean = 360 * ease(min(max((c - 0.05) / 0.4, 0), 1))
                p.swing = 15 * sin(t * 2 * .pi / 1.1)
                p.eyes = .happy
            case .alert:
                let c = t.truncatingRemainder(dividingBy: 1.8)
                p.flash = max(bump(c, 0, 0.3), bump(c, 0.35, 0.65)) * 0.85
                p.shake = c < 0.7 ? 3 * sin(c * 2 * .pi * 9) : 0
                p.glow = p.flash
                if mood == .normal { p.eyes = .grumpy }
            case .sleep:
                p.eyes = .closed
                p.open = 1
                p.hop = 1 * sin(t * 2 * .pi / 4.5)
                p.ringOpacity = 0.45 + 0.4 * (0.5 + 0.5 * sin(t * 2 * .pi / 4.5))
            case .glow:
                p.glow = 0.5 + 0.5 * sin(t * 2 * .pi / 2.2)
                p.hop = 1 * sin(t * 2 * .pi / 3.4)
                if mood == .normal { p.express(Beat.at(t, set: .idle)) }
            }
            if let gaze { p.look = gaze }
            return p
        }

        mutating func express(_ b: Beat) {
            look = b.look
            eyeW = b.eyeW
            eyeH = b.eyeH
            lean += b.lean
            dart = b.dart
        }

        /// One expression Orbit holds for a moment: where it looks, the shape of each eye, a head tilt.
        /// A new one comes every ~1.1 s (sometimes it just keeps the last), and the eyes dart to it
        /// with a little overshoot, so Orbit always seems to be noticing something.
        struct Beat {
            var look = CGVector.zero
            var eyeW = (1.0, 1.0), eyeH = (1.0, 1.0)
            var lean = 0.0
            var dart = 0.0

            enum Set { case idle, working }
            static let length = 1.1

            static func at(_ t: Double, set: Set) -> Beat {
                let n = floor(t / length), phase = t - n * length
                let to = pick(n, set), from = pick(n - 1, set)
                let move = min(phase / 0.3, 1)
                var b = mix(from, to, overshoot(move))
                // Eyes stretch in the direction they dart, then settle.
                let distance = hypot(to.look.dx - from.look.dx, to.look.dy - from.look.dy)
                b.dart = move < 1 ? sin(move * .pi) * min(distance, 1.2) * 0.22 : 0
                return b
            }

            static func pick(_ n: Double, _ set: Set) -> Beat {
                let r = rand(n * 1.37 + 11), side = rand(n + 5) < 0.5 ? -1.0 : 1.0
                var b = Beat()
                let a = rand(n + 2) * 2 * .pi
                switch set {
                case .working:
                    // Reading: sweeps across and down, focused, now and then a closer look.
                    b.look = CGVector(dx: side * (0.5 + 0.5 * rand(n + 3)), dy: 0.1 + 0.5 * rand(n + 4))
                    b.eyeH = (0.62, 0.62)
                    if r < 0.15 { b.eyeH = (0.3, 0.3); b.eyeW = (1.1, 1.1) }               // concentrating
                    else if r < 0.25 { b.look = .zero; b.eyeH = (1, 1) }                    // looks up at you
                    else if r < 0.33 { b.look = CGVector(dx: 0.3 * side, dy: -0.9); b.eyeH = (0.8, 0.8) } // hmm
                case .idle:
                    switch r {
                    case ..<0.22:  // looks somewhere
                        let m = 0.6 + 0.4 * rand(n + 3)
                        b.look = CGVector(dx: cos(a) * m, dy: sin(a) * 0.8 * m)
                    case ..<0.36:  // back at you, a little bigger
                        b.eyeW = (1.08, 1.08); b.eyeH = (1.1, 1.1)
                    case ..<0.46:  // curious: head tilt, one eye bigger
                        b.look = CGVector(dx: 0.7 * side, dy: -0.2)
                        b.lean = 8 * side
                        b.eyeW = side > 0 ? (0.9, 1.15) : (1.15, 0.9)
                        b.eyeH = side > 0 ? (0.85, 1.15) : (1.15, 0.85)
                    case ..<0.54:  // squint, like a smile
                        b.eyeH = (0.32, 0.32); b.eyeW = (1.12, 1.12)
                    case ..<0.61:  // surprised: small round eyes
                        b.eyeW = (0.66, 0.66); b.eyeH = (0.5, 0.5)
                        b.look = CGVector(dx: 0, dy: -0.3)
                    case ..<0.68:  // peeks down
                        b.look = CGVector(dx: 0.3 * side, dy: 1.25)
                        b.eyeH = (0.8, 0.8)
                    case ..<0.74:  // wink
                        b.eyeH = side > 0 ? (1, 0.12) : (0.12, 1)
                        b.eyeW = side > 0 ? (1, 1.15) : (1.15, 1)
                        b.lean = -4 * side
                    case ..<0.80:  // not so sure: one eye half shut
                        b.look = CGVector(dx: 0.6 * side, dy: 0)
                        b.eyeH = side > 0 ? (1, 0.5) : (0.5, 1)
                    case ..<0.85:  // sleepy
                        b.eyeH = (0.45, 0.45)
                        b.look = CGVector(dx: 0, dy: 0.5)
                    case ..<0.90:  // looks up, thinking
                        b.look = CGVector(dx: 0.5 * side, dy: -1)
                    default:       // keeps what it was doing
                        return n > 0 && rand(n + 9) < 0.9 ? pick(n - 1, set) : b
                    }
                }
                return b
            }

            static func mix(_ a: Beat, _ b: Beat, _ k: Double) -> Beat {
                func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
                var o = Beat()
                o.look = CGVector(dx: m(a.look.dx, b.look.dx), dy: m(a.look.dy, b.look.dy))
                o.eyeW = (max(m(a.eyeW.0, b.eyeW.0), 0.3), max(m(a.eyeW.1, b.eyeW.1), 0.3))
                o.eyeH = (max(m(a.eyeH.0, b.eyeH.0), 0.08), max(m(a.eyeH.1, b.eyeH.1), 0.08))
                o.lean = m(a.lean, b.lean)
                return o
            }

            /// 0 → 1 with a small springy overshoot.
            static func overshoot(_ x: Double) -> Double {
                let c = 2.2, y = x - 1
                return 1 + (c + 1) * y * y * y + c * y * y
            }
        }

        /// 1 open … 0 shut. Blinks every ~4 s, sometimes twice.
        static func blink(_ t: Double) -> Double {
            let n = floor(t / 4.3), phase = t - n * 4.3
            let start = 3.4 + rand(n + 7) * 0.7
            func shut(_ at: Double) -> Double {
                let d = abs(phase - at - 0.06)
                return d < 0.06 ? d / 0.06 : 1
            }
            var v = shut(start)
            if rand(n + 3) < 0.25 { v = min(v, shut(start + 0.2)) }
            return v
        }

        static func rand(_ n: Double) -> Double {
            let x = sin(n * 12.9898) * 43758.5453
            return x - floor(x)
        }
        static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        /// 0 → 1 → 0 between a and b.
        static func bump(_ x: Double, _ a: Double, _ b: Double) -> Double {
            guard x > a, x < b else { return 0 }
            return sin((x - a) / (b - a) * .pi)
        }
    }

    // MARK: Drawing

    private static func draw(_ ctx: inout GraphicsContext, canvas: CGSize, pose: Pose,
                             theme: Appearance.Companion, tint: Color) {
        let u = canvas.width / 104
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x + 2) * u, y: (y + 2) * u) }
        let center = pt(50, 52), foot = pt(50, 82)

        // Whole body: hop, squash from the bottom, lean or spin around the middle, shake.
        ctx.translateBy(x: (pose.shake + pose.sway) * u, y: -pose.hop * u)
        ctx.translateBy(x: foot.x, y: foot.y)
        ctx.scaleBy(x: pose.squashX, y: pose.squashY)
        ctx.translateBy(x: -foot.x, y: -foot.y)
        if pose.lean != 0 {
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(pose.lean))
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        let ringColor = pose.rainbow.map { Color(hue: $0, saturation: 0.55, brightness: 1) } ?? theme.ring
        let lineWidth = 8.5 * u
        func ringContext() -> GraphicsContext {
            var r = ctx
            r.translateBy(x: center.x, y: center.y)
            r.rotate(by: .degrees(24 + pose.swing))
            r.scaleBy(x: pose.ringScale, y: pose.ringScale)
            r.opacity = pose.ringOpacity
            if pose.glow > 0.01 { r.addFilter(.shadow(color: tint.opacity(pose.glow), radius: 4 * u)) }
            return r
        }
        let rx = 47 * u, ry = 15 * u
        var front = Path()
        for i in 0...24 {
            let a = Double(i) / 24 * .pi
            let p = CGPoint(x: rx * cos(a), y: ry * sin(a))
            if i == 0 { front.move(to: p) } else { front.addLine(to: p) }
        }
        let moonPoint = pose.moon.map { CGPoint(x: rx * cos($0), y: ry * sin($0)) }
        let moonInFront = pose.moon.map { sin($0) > 0 } ?? false
        func drawMoon(_ r: GraphicsContext) {
            guard let m = moonPoint else { return }
            let s = 5.5 * u
            r.fill(Path(ellipseIn: CGRect(x: m.x - s, y: m.y - s, width: s * 2, height: s * 2)), with: .color(theme.body))
            r.stroke(Path(ellipseIn: CGRect(x: m.x - s, y: m.y - s, width: s * 2, height: s * 2)), with: .color(ringColor), lineWidth: 1.6 * u)
        }

        // Back of the ring, behind the body.
        let back = ringContext()
        back.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)), with: .color(ringColor), lineWidth: lineWidth)
        if !moonInFront { drawMoon(back) }

        // Body, with a flash of the tint colour when alerting.
        let body = Path(ellipseIn: CGRect(x: center.x - 30 * u, y: center.y - 30 * u, width: 60 * u, height: 60 * u))
        ctx.fill(body, with: .color(theme.body))
        if pose.flash > 0.01 { ctx.fill(body, with: .color(tint.opacity(pose.flash))) }

        drawEyes(&ctx, pose: pose, u: u, pt: pt, color: theme.eyes)

        // Front of the ring, over the body.
        let fr = ringContext()
        fr.stroke(front, with: .color(ringColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        if moonInFront { drawMoon(fr) }
    }

    private static func drawEyes(_ ctx: inout GraphicsContext, pose: Pose, u: CGFloat,
                                 pt: (Double, Double) -> CGPoint, color: Color) {
        let shift = (x: pose.look.dx * 4.5, y: pose.look.dy * 4)
        let eyes = [(52.5, 40.0), (69.5, 49.5)]
        // The face sits on a sphere turning on the ring's axis (tilted 24°): work in that tilted frame,
        // move each eye round by `spin`, and narrow it as it turns away; hidden behind the planet.
        let tilt = 24.0 * .pi / 180, radius = 28.0
        for (i, e) in eyes.enumerated() {
            let dx = e.0 + shift.x - 50, dy = e.1 + shift.y - 52
            let ax = dx * cos(tilt) + dy * sin(tilt), ay = -dx * sin(tilt) + dy * cos(tilt)
            let across = sqrt(max(radius * radius - ay * ay, 1))
            let rest = asin(min(max(ax / across, -1), 1))
            let lon = rest + pose.spin
            let facing = cos(lon)
            guard facing > 0.08 else { continue }
            let nx = across * sin(lon)
            let c = pt(50 + nx * cos(tilt) - ay * sin(tilt), 52 + nx * sin(tilt) + ay * cos(tilt))
            var g = ctx
            g.translateBy(x: c.x, y: c.y)
            g.rotate(by: .degrees(24))
            g.scaleBy(x: min(facing / max(cos(rest), 0.2), 1), y: 1)
            let line = StrokeStyle(lineWidth: 3.6 * u, lineCap: .round, lineJoin: .round)
            var mood = pose.eyes
            if mood == .wink { mood = i == 1 ? .closed : .normal }
            let sizeW = (i == 0 ? pose.eyeW.0 : pose.eyeW.1) * (1 + pose.dart)
            let sizeH = (i == 0 ? pose.eyeH.0 : pose.eyeH.1) * (1 - pose.dart * 0.5)
            func oval(_ w: Double, _ h: Double) {
                let ww = w * sizeW, hh = max(h * sizeH * pose.open, 0.5)
                let r = min(ww, hh)
                g.fill(Path(roundedRect: CGRect(x: -ww * u, y: -hh * u, width: 2 * ww * u, height: 2 * hh * u),
                            cornerRadius: r * u), with: .color(color))
            }
            switch mood {
            case .normal, .wink: oval(5.4, 7.6)
            case .wide: oval(6.4, 9)
            case .squint: oval(5, 2)
            case .grumpy:
                oval(4.8, 3.6)
                var brow = Path()
                brow.move(to: CGPoint(x: -5.5 * u, y: (i == 0 ? -9.5 : -7) * u))
                brow.addLine(to: CGPoint(x: 5.5 * u, y: (i == 0 ? -7 : -9.5) * u))
                g.stroke(brow, with: .color(color), style: line)
            case .happy:
                var arc = Path()
                arc.move(to: CGPoint(x: -5 * u, y: 2 * u))
                arc.addQuadCurve(to: CGPoint(x: 5 * u, y: 2 * u), control: CGPoint(x: 0, y: -7 * u))
                g.stroke(arc, with: .color(color), style: line)
            case .closed:
                var arc = Path()
                arc.move(to: CGPoint(x: -5 * u, y: -1 * u))
                arc.addQuadCurve(to: CGPoint(x: 5 * u, y: -1 * u), control: CGPoint(x: 0, y: 5 * u))
                g.stroke(arc, with: .color(color), style: line)
            }
        }
    }
}

/// Orbit as a button: grows a little on hover and glances at you, opens Ask on click.
struct OrbitButton: View {
    var size: CGFloat = 26
    var motion: OrbitView.Motion = .idle
    var mood: OrbitView.Mood = .normal
    var tint: Color = Tokens.attention
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            OrbitView(size: size, mood: hovering ? .happy : mood, motion: hovering ? .glow : motion, tint: hovering ? .white : tint)
                .scaleEffect(hovering ? 1.15 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask Orbit (⌥K)")
    }
}

extension OrbitView {
    /// An Orbit for one agent session: its own colour per project, acting out what the agent is doing.
    static func agent(project: String, state: AgentsModule.Session.State, size: CGFloat) -> OrbitView {
        let pick = agentColors(project)
        switch state {
        case .working: return OrbitView(size: size, mood: .squint, motion: .working, colors: pick)
        case .needsInput: return OrbitView(size: size, mood: .wide, motion: .nudge, tint: Tokens.attention, colors: pick)
        case .done: return OrbitView(size: size, mood: .happy, motion: .idle, colors: pick)
        }
    }
}
