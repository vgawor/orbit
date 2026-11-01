import SwiftUI

/// Design tokens (design canvas "Orbit Liquid Glass"). The notch is always black, in light and dark mode.
/// Surfaces are see-through white so they read as glass on the glass panel and as dark grey on black.
enum Tokens {
    static let surface = Color.white.opacity(0.07)
    static let surface2 = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.1)
    static let secondary = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.32)
    static let live = Color(red: 0.204, green: 0.780, blue: 0.349)    // #34C759
    static let attention = Color(red: 1.0, green: 0.690, blue: 0.125) // #FFB020
    static let error = Color(red: 1.0, green: 0.271, blue: 0.227)     // #FF453A
    static let zoom = Color(red: 0.176, green: 0.549, blue: 1.0)      // #2D8CFF
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// Rounded card used inside the open panel.
struct NotchCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(22)
    }
}

/// Small uppercase label at the top of a card.
struct CardLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Tokens.faint)
    }
}

/// The companion in small places (Focus breaks, lists). Kept as a name so older call sites read well.
struct CompanionView: View {
    var size: CGFloat = 16
    var motion: OrbitView.Motion = .idle
    var body: some View { OrbitView(size: size * 1.6, motion: motion) }
}
