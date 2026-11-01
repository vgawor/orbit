import SwiftUI

/// Fun add-ons. Return each one here; they show up in Settings → Add-ons.
@MainActor
enum FunAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [
            DecideAddOn(openPanel: ctx.openPanel),
            ArcadeAddOn(openPanel: ctx.openPanel),
            OnThisDayAddOn(openPanel: ctx.openPanel),
            WeatherAddOn(openPanel: ctx.openPanel),
            FunFactAddOn(openPanel: ctx.openPanel),
        ]
    }
}

// MARK: - Small pieces shared by the Fun add-ons

/// A tiny random number generator that gives the same numbers for the same seed (tests, previews).
struct FunSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A row of glass capsules where one is picked (modes, dice kinds).
struct FunSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String, symbol: String?)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { withAnimation(Tokens.spring) { selection = option.value } } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        Text(option.title).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(on ? .white : Tokens.secondary)
                    .glassSurface(Capsule(), selected: on, interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The add-on's own tint (the Fun category colour).
extension Color {
    static let funTint = AddOnCategory.fun.tint
}

/// Orbit with a little prop: a history scroll to read, or a light bulb for a bright idea.
struct FunPropOrbit: View {
    enum Prop { case scroll, bulb }
    let prop: Prop
    var size: CGFloat = 50
    var motion: OrbitView.Motion = .idle
    var mood: OrbitView.Mood = .normal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let u = size / 104
        ZStack {
            switch prop {
            case .scroll:
                // Reading the scroll it holds in front of its ring.
                OrbitView(size: size, mood: mood, motion: reduceMotion ? .still : motion,
                          gaze: motion == .idle ? CGVector(dx: 0.5, dy: 0.9) : nil)
                FunScroll()
                    .frame(width: 34 * u, height: 40 * u)
                    .rotationEffect(.degrees(-14))
                    .offset(x: 30 * u, y: 26 * u)
            case .bulb:
                OrbitView(size: size, mood: mood, motion: reduceMotion ? .still : motion, gaze: CGVector(dx: 0.4, dy: -0.9))
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 30 * u, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.35))
                    .shadow(color: Color(red: 1, green: 0.8, blue: 0.3).opacity(0.8), radius: 8 * u)
                    .offset(x: 34 * u, y: -38 * u)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityElement()
        .accessibilityLabel(prop == .scroll ? "Orbit reading a history scroll" : "Orbit with a bright idea")
    }
}

/// A rolled parchment with a few lines of writing.
private struct FunScroll: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, roll = h * 0.16
            let paper = Color(red: 0.98, green: 0.9, blue: 0.72), edge = Color(red: 0.82, green: 0.66, blue: 0.42)
            ctx.fill(Path(CGRect(x: w * 0.1, y: roll / 2, width: w * 0.8, height: h - roll)), with: .color(paper))
            var lines = Path()
            for i in 0..<4 {
                let y = roll + (h - 2 * roll) * (0.2 + 0.2 * Double(i))
                lines.move(to: CGPoint(x: w * 0.22, y: y)); lines.addLine(to: CGPoint(x: w * (i == 3 ? 0.55 : 0.78), y: y))
            }
            ctx.stroke(lines, with: .color(edge.opacity(0.8)), lineWidth: max(h * 0.035, 0.8))
            for y in [0, h - roll] {
                let r = CGRect(x: 0, y: y, width: w, height: roll)
                ctx.fill(Path(roundedRect: r, cornerRadius: roll / 2), with: .color(edge))
                ctx.fill(Path(roundedRect: r.insetBy(dx: w * 0.06, dy: roll * 0.22), cornerRadius: roll / 3), with: .color(paper))
            }
        }
    }
}
