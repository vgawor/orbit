import SwiftUI

// Orbit acting things out in the Developers (and Security) add-ons.
// Props are plain SwiftUI shapes and SF Symbols, drawn around `OrbitView`, never inside it.

/// A compact Home card shared by the Developers and Security add-ons:
/// a small Orbit scene, a label, one headline, one detail line and optional buttons on the right.
struct DevSecHomeCard<Art: View, Trailing: View>: View {
    let label: String
    let title: String
    var detail: String? = nil
    var titleTint: Color = .white
    var detailTint: Color = Tokens.secondary
    let open: () -> Void
    @ViewBuilder var art: Art
    @ViewBuilder var trailing: Trailing

    var body: some View {
        NotchCard {
            HStack(spacing: 12) {
                art.frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    CardLabel(label)
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(titleTint).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(detailTint).lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                trailing.fixedSize()
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minHeight: 78)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

extension DevSecHomeCard where Trailing == EmptyView {
    init(label: String, title: String, detail: String? = nil, titleTint: Color = .white,
         detailTint: Color = Tokens.secondary, open: @escaping () -> Void, @ViewBuilder art: () -> Art) {
        self.init(label: label, title: title, detail: detail, titleTint: titleTint, detailTint: detailTint,
                  open: open, art: art, trailing: { EmptyView() })
    }
}

/// Orbit popping up out of a port, like a head out of a manhole. Sleeps in it when nothing listens.
struct DevPortOrbit: View {
    var size: CGFloat
    var awake = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hole = CGSize(width: size * 0.9, height: size * 0.24)
        let line = size * 0.74                      // the hole's middle, from the top
        ZStack(alignment: .top) {
            // Back of the hole.
            Ellipse().fill(Color.black.opacity(0.55))
                .frame(width: hole.width, height: hole.height)
                .offset(y: line - hole.height / 2)
            // Orbit, cut off where it goes down into the hole.
            OrbitView(size: size * 0.78, mood: awake ? .normal : .closed,
                      motion: reduceMotion ? .still : (awake ? .idle : .sleep))
                .offset(y: awake ? size * 0.2 : size * 0.3)
                .frame(width: size, height: line, alignment: .top)
                .clipped()
            // Front rim, over Orbit's middle.
            Ellipse().trim(from: 0, to: 0.5)   // lower half: the near edge
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: max(1.2, size * 0.035), lineCap: .round))
                .frame(width: hole.width, height: hole.height)
                .offset(y: line - hole.height / 2)
        }
        .frame(width: size, height: size, alignment: .top)
        .accessibilityLabel(awake ? "Orbit peeking out of a port" : "Orbit asleep in a port")
    }
}

/// Orbit riding a little wooden crate, rocking gently while containers run.
struct DevCrateOrbit: View {
    var size: CGFloat
    var mood: OrbitView.Mood = .normal
    var motion: OrbitView.Motion = .idle
    /// Rock side to side, as if the crate were afloat.
    var rocking = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let wood = Color(red: 0.74, green: 0.55, blue: 0.36)
    static let woodDark = Color(red: 0.45, green: 0.31, blue: 0.19)

    var body: some View {
        let calm = reduceMotion || !rocking
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: calm)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let tilt = calm ? 0 : 3.5 * sin(t * 2 * .pi / 3.2)
            let bob = calm ? 0 : 1.2 * sin(t * 2 * .pi / 1.6)
            ZStack(alignment: .bottom) {
                OrbitView(size: size * 0.7, mood: mood, motion: reduceMotion ? .still : motion)
                    .offset(y: -size * 0.27)
                crate
            }
            .frame(width: size, height: size, alignment: .bottom)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .offset(y: bob)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Orbit riding a crate")
    }

    private var crate: some View {
        let w = size * 0.74, h = size * 0.34, line = max(1, size * 0.03)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.05, style: .continuous).fill(Self.wood)
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in
                    Spacer(minLength: 0)
                    Rectangle().fill(Self.woodDark.opacity(0.55)).frame(height: line)
                }
                Spacer(minLength: 0)
            }
            // The diagonal brace every crate has.
            Path { p in
                p.move(to: CGPoint(x: w * 0.12, y: h * 0.86))
                p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.14))
            }
            .stroke(Self.woodDark.opacity(0.7), lineWidth: line * 1.4)
            RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                .strokeBorder(Self.woodDark, lineWidth: line * 1.2)
        }
        .frame(width: w, height: h)
    }
}

/// Orbit for one CI state: busy while running, a happy spin for a fresh pass, alarmed at a failure.
struct DevActionsOrbit: View {
    var size: CGFloat
    var state: ActionsRun.State?
    /// A success counts as fresh (and gets a celebration) for this long.
    var fresh = false
    /// Home cards stay calmer: no flashing.
    var calm = false

    var body: some View {
        let (mood, motion, tint): (OrbitView.Mood, OrbitView.Motion, Color) = switch state {
        case .running: (.squint, .working, Tokens.zoom)
        case .queued: (.normal, .thinking, Tokens.attention)
        case .success: fresh ? (.happy, .celebrate, Tokens.live) : (.happy, .idle, Tokens.live)
        case .failure: calm ? (.grumpy, .glow, Tokens.error) : (.grumpy, .alert, Tokens.error)
        case .cancelled, .other: (.normal, .idle, Tokens.attention)
        case nil: (.normal, .idle, Tokens.attention)
        }
        OrbitView(size: size, mood: mood, motion: motion, tint: tint)
    }
}

/// Orbit keeping watch over your sites: asleep when all is well, alarmed when one is down.
struct DevUptimeOrbit: View {
    var size: CGFloat
    /// nil: nothing checked yet.
    var down: Int?
    var calm = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch down {
            case nil: OrbitView(size: size, motion: .idle)
            case 0: OrbitView(size: size, mood: .closed, motion: .sleep)
            default: OrbitView(size: size, mood: .wide, motion: calm ? .glow : .alert, tint: Tokens.error)
            }
            if down == 0 {
                Image(systemName: "zzz").font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(Tokens.secondary)
                    .offset(x: size * 0.06, y: -size * 0.04)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Orbit for the toolbox: thinks while you type, happy with a good result, grumpy at a bad one.
struct DevToolboxOrbit: View {
    var size: CGFloat
    var thinking: Bool
    /// nil: no input yet.
    var ok: Bool?

    var body: some View {
        if thinking {
            OrbitView(size: size, mood: .squint, motion: .thinking)
        } else {
            switch ok {
            case true?: OrbitView(size: size, mood: .happy, motion: .idle)
            case false?: OrbitView(size: size, mood: .grumpy, motion: .idle)
            case nil: OrbitView(size: size, motion: .idle)
            }
        }
    }
}
