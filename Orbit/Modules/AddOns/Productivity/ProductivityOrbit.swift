import SwiftUI

/// How Orbit looks in a productivity add-on: a mood, a motion, a signal colour and how much extra it hops.
/// Worked out by small pure functions (in each add-on) so the choice is easy to test.
struct ProductivityOrbit: Equatable {
    var mood: OrbitView.Mood
    var motion: OrbitView.Motion
    var tint: Color = Tokens.attention
    /// Extra bounce on top of the motion, in points at 40 pt size (0 = none).
    var hop: CGFloat = 0

    static let calm = ProductivityOrbit(mood: .normal, motion: .idle)
    static let happy = ProductivityOrbit(mood: .happy, motion: .idle)
    static let asleep = ProductivityOrbit(mood: .closed, motion: .sleep)
}

/// Orbit drawn from a `ProductivityOrbit`, with its extra hop when it has one.
struct ProductivityOrbitView: View {
    let look: ProductivityOrbit
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        let hop = reduceMotion ? 0 : look.hop * size / 40
        OrbitView(size: size, mood: look.mood, motion: look.motion, tint: look.tint)
            .offset(y: up ? -hop : 0)
            .animation(hop > 0 ? .easeInOut(duration: 0.32).repeatForever(autoreverses: true) : .default, value: up)
            .onAppear { up = hop > 0 }
            .onChange(of: hop) { _, h in up = h > 0 }
    }
}

/// Orbit catching things: whenever `token` changes, a little page drops in from above and Orbit
/// catches it with a happy squash. Used by Clipboard (each copy) and Snippets (each paste-ready copy).
struct CatchingOrbit<Token: Equatable>: View {
    let token: Token
    var size: CGFloat = 36
    var symbol = "doc.text.fill"
    var resting: ProductivityOrbit = .calm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPage = false
    @State private var landed = false
    @State private var caught = false
    @State private var round = 0

    var body: some View {
        ZStack {
            if showPage {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(y: landed ? 0 : -size * 0.8)
                    .scaleEffect(landed ? 0.4 : 1)
                    .opacity(landed ? 0 : 1)
            }
            OrbitView(size: size, mood: caught ? .happy : resting.mood, motion: caught ? .idle : resting.motion,
                      tint: resting.tint, gaze: showPage && !landed ? CGVector(dx: 0, dy: -1) : nil)
                .scaleEffect(x: caught && !reduceMotion ? 1.12 : 1, y: caught && !reduceMotion ? 0.9 : 1, anchor: .bottom)
        }
        .frame(width: size, height: size)
        .onChange(of: token) { _, _ in
            round += 1
            let mine = round
            guard !reduceMotion else {
                caught = true
                after(0.9) { if round == mine { caught = false } }
                return
            }
            landed = false
            showPage = true
            after(0.05) {
                guard round == mine else { return }
                withAnimation(.easeIn(duration: 0.4)) { landed = true }
            }
            after(0.42) {
                guard round == mine else { return }
                showPage = false
                withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { caught = true }
            }
            after(1.2) {
                guard round == mine else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { caught = false }
            }
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }
}
