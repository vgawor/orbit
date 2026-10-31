import AppKit
import SwiftUI

/// Liquid Glass for Orbit (see design canvas "Orbit Liquid Glass").
///
/// - The notch and the top of every panel stay pure black, so they blend with the hardware notch.
/// - Below that, the panel is dark glass that blurs the desktop behind it.
/// - Cards, the tab bar and secondary buttons are glass on top of that; the one main action is a white pill.
/// macOS 26 uses Apple's Liquid Glass; macOS 14–15 get a frosted blur. Settings → Appearance can switch
/// back to solid black.
@MainActor
enum Glass {
    /// Real glass can't be drawn into snapshot PNGs, so snapshots use flat look-alikes.
    static var flat: Bool { ModuleRegistry.isPreview || Appearance.shared.panelStyle == .solid }
    /// The black band at the top of a panel, below which it fades into glass.
    static let blackFade: CGFloat = 70
}

/// The open panel's background: black where it meets the notch, fading into dark glass.
struct PanelBackground: View {
    /// Height of the pure black band at the top (the notch height plus a little). 0 = glass all the way,
    /// for screens without a notch.
    let blackTop: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            ZStack {
                if Appearance.shared.panelStyle == .solid {
                    Color.black
                } else {
                    if ModuleRegistry.isPreview {
                        Color(white: 0.06).opacity(0.82)
                    } else {
                        DesktopGlass()
                        Color.black.opacity(0.42)
                    }
                    if blackTop > 0 { LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: min(blackTop / h, 1)),
                        .init(color: .black.opacity(0), location: min((blackTop + Glass.blackFade) / h, 1)),
                    ], startPoint: .top, endPoint: .bottom) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            // The glass edge: a thin light line along the bottom curve.
            if Appearance.shared.panelStyle == .glass {
                LinearGradient(colors: [.clear, .white.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 1.5).blendMode(.plusLighter)
            }
        }
    }
}

/// Glass that blurs what's behind the window (the desktop and other apps).
struct DesktopGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.cornerRadius = 0
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        return blur
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
extension View {
    /// A glass card, button or bar. `selected` makes it brighter (selected tab, your chat bubble).
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, selected: Bool = false, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *), !Glass.flat {
            let base: SwiftUI.Glass = selected ? .regular.tint(.white.opacity(0.22)) : .regular.tint(.black.opacity(0.08))
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background {
                shape.fill(Color.white.opacity(selected ? 0.16 : 0.07))
                    .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(selected ? 0.35 : 0.2), .white.opacity(0.04)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1))
            }
        }
    }

    func glassCard(_ radius: CGFloat = 22) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Groups glass shapes so they blend and morph together (macOS 26), or does nothing on older systems.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *), !Glass.flat {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Secondary button: a glass capsule. (The main action uses `PillButton`, a white pill.)
struct GlassPillButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(.white)
            .glassSurface(Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A scroll view that layout snapshots can draw (ImageRenderer leaves scroll views empty).
struct NotchScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if ModuleRegistry.isPreview {
            VStack(spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView(showsIndicators: false) { content }
        }
    }
}
