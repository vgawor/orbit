import SwiftUI

// Orbit acting things out in the Security add-ons. Props are plain shapes and SF Symbols
// laid over `OrbitView`, using its 104-unit design grid (body r30 at 52,54; eyes near 56,43 and 70,51).

/// Orbit with a sleep mask over its eyes: it doesn't look while a password is on screen.
struct SecBlindfoldOrbit: View {
    var size: CGFloat
    var blindfolded: Bool
    var mood: OrbitView.Mood = .normal
    var motion: OrbitView.Motion = .idle

    var body: some View {
        let ring = Appearance.shared.companion.ring
        ZStack {
            OrbitView(size: size, mood: blindfolded ? .closed : mood, motion: blindfolded ? .still : motion)
            if blindfolded {
                Canvas { ctx, s in
                    let u = s.width / 104
                    let body = Path(ellipseIn: CGRect(x: 22 * u, y: 24 * u, width: 60 * u, height: 60 * u))
                    var strap = ctx
                    strap.clip(to: body)
                    strap.translateBy(x: 63 * u, y: 47 * u)
                    strap.rotate(by: .degrees(24))
                    strap.fill(Path(CGRect(x: -40 * u, y: -1.8 * u, width: 80 * u, height: 3.6 * u)), with: .color(ring.opacity(0.85)))
                    var mask = ctx
                    mask.translateBy(x: 63 * u, y: 47 * u)
                    mask.rotate(by: .degrees(24))
                    let r = CGRect(x: -16 * u, y: -7.5 * u, width: 32 * u, height: 15 * u)
                    mask.fill(Path(roundedRect: r, cornerRadius: 7.5 * u), with: .color(ring))
                    mask.stroke(Path(roundedRect: r, cornerRadius: 7.5 * u), with: .color(.black.opacity(0.25)), lineWidth: 1.2 * u)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(blindfolded ? "Orbit, eyes covered" : "Orbit")
    }
}

/// Orbit holding a key inside a countdown ring, its eyes following the ring as the code runs out.
struct SecKeyOrbit: View {
    var size: CGFloat
    /// 0…1 of the code's time left; nil draws no ring (no accounts yet).
    var progress: Double?
    var urgent = false

    var body: some View {
        ZStack {
            if let progress {
                Circle().stroke(Tokens.surface2, lineWidth: size * 0.05)
                Circle().trim(from: 0, to: progress)
                    .stroke(urgent ? Tokens.attention : SecurityAddOns.tint,
                            style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            OrbitView(size: size * (progress == nil ? 0.9 : 0.7), mood: urgent ? .wide : .normal,
                      motion: progress == nil ? .idle : .still, gaze: progress.map(Self.gaze))
            Image(systemName: "key.fill")
                .font(.system(size: size * 0.24, weight: .bold))
                .foregroundStyle(SecurityAddOns.tint)
                .rotationEffect(.degrees(-35))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: size * 0.28, y: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Orbit with a key")
    }

    /// Where the end of the ring is, as a look direction (clockwise from the top).
    static func gaze(_ progress: Double) -> CGVector {
        let a = progress * 2 * .pi
        return CGVector(dx: sin(a), dy: -cos(a))
    }
}

/// Orbit with a small shield when a VPN is on.
struct SecShieldOrbit: View {
    var size: CGFloat
    var on: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            OrbitView(size: size, mood: on ? .happy : .normal, motion: on ? .glow : .idle, tint: Tokens.live)
            if on {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Tokens.live)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .offset(x: -size * 0.02, y: size * 0.02)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(on ? "Orbit with a shield" : "Orbit")
    }
}

/// Orbit wide awake under an "on air" light while the camera or mic is in use; asleep otherwise.
struct SecOnAirOrbit: View {
    var size: CGFloat
    var camera: Bool
    var mic: Bool
    /// Show the small "ON AIR" sign above Orbit.
    var sign = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var live: Bool { camera || mic }
    private var tint: Color { camera ? Tokens.live : Tokens.attention }

    var body: some View {
        VStack(spacing: size * 0.06) {
            if sign {
                Text("ON AIR")
                    .font(.system(size: max(7, size * 0.13), weight: .heavy, design: .rounded)).tracking(0.6)
                    .foregroundStyle(live ? .black : Tokens.faint)
                    .padding(.horizontal, size * 0.08).padding(.vertical, size * 0.025)
                    .background(Capsule().fill(live ? tint : Tokens.surface))
                    .shadow(color: live ? tint.opacity(pulse ? 0.9 : 0.35) : .clear, radius: pulse ? 8 : 3)
                    .fixedSize()
            }
            let s = sign ? size * 0.74 : size
            ZStack(alignment: .topTrailing) {
                if camera {
                    OrbitView(size: s, mood: .wide, motion: .glow, tint: tint)
                } else if mic {
                    OrbitView(size: s, mood: .wide, motion: .listening, tint: tint)
                } else {
                    OrbitView(size: s, mood: .closed, motion: .sleep)
                    Image(systemName: "zzz").font(.system(size: size * 0.15, weight: .semibold))
                        .foregroundStyle(Tokens.secondary).offset(x: size * 0.06)
                }
                if live && !sign {
                    // No room for the sign: a small "on air" light instead.
                    SecStatusDot(color: tint, size: max(6, size * 0.15))
                        .opacity(pulse ? 1 : 0.55)
                        .offset(x: -size * 0.04, y: size * 0.06)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(live ? "Orbit on air" : "Orbit asleep")
    }
}

/// Orbit the inspector, with a magnifying glass: busy while checking, happy when all is good,
/// alarmed when something needs a look.
struct SecInspectorOrbit: View {
    enum Verdict { case checking, good, warn, unknown }
    var size: CGFloat
    var verdict: Verdict
    /// Home cards stay calmer: a glow instead of flashing.
    var calm = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch verdict {
            case .checking: OrbitView(size: size * 0.86, mood: .squint, motion: .working)
            case .good: OrbitView(size: size * 0.86, mood: .happy, motion: .idle)
            case .warn: OrbitView(size: size * 0.86, mood: .wide, motion: calm ? .glow : .alert, tint: Tokens.attention)
            case .unknown: OrbitView(size: size * 0.86, motion: .idle)
            }
            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2)
                .offset(x: size * 0.02, y: size * 0.02)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityLabel("Orbit inspecting")
    }
}
