import SwiftUI

/// How Orbit looks in a finance add-on: a mood, a motion and a signal colour.
/// Worked out by small pure functions (in each add-on) so the choice is easy to test.
struct FinanceOrbit: Equatable {
    var mood: OrbitView.Mood
    var motion: OrbitView.Motion
    var tint: Color = Tokens.attention

    static let calm = FinanceOrbit(mood: .normal, motion: .idle)
    static let happy = FinanceOrbit(mood: .happy, motion: .idle)
    static let thinking = FinanceOrbit(mood: .normal, motion: .thinking)
}

/// Orbit drawn from a `FinanceOrbit`.
struct FinanceOrbitView: View {
    let look: FinanceOrbit
    var size: CGFloat = 34
    var body: some View {
        OrbitView(size: size, mood: look.mood, motion: look.motion, tint: look.tint)
    }
}

/// Orbit doing the sums: thinks for a moment whenever `value` changes, then shows the answer happily.
/// Used by the currency converter and the VAT calculator.
struct CalculatingOrbit<Value: Equatable>: View {
    let value: Value
    var size: CGFloat = 44
    /// Look when Orbit isn't busy working something out.
    var resting: FinanceOrbit = .happy
    @State private var thinking = false
    @State private var token = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FinanceOrbitView(look: thinking ? .thinking : resting, size: size)
            .scaleEffect(thinking && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: thinking)
            .onChange(of: value) { _, _ in
                token += 1
                let mine = token
                thinking = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(750))
                    if token == mine { thinking = false }
                }
            }
    }
}
