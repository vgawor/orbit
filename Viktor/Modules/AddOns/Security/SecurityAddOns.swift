import AppKit
import SwiftUI

/// Security add-ons. Return each one here; they show up in Settings → Add-ons.
/// All of them only read: none changes a system setting.
@MainActor
enum SecurityAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [
            PasswordsAddOn(ctx),
            AuthenticatorAddOn(),
            NetworkAddOn(ctx),
            PrivacyAddOn(ctx),
            CheckupAddOn(ctx),
        ]
    }

    static let tint = AddOnCategory.security.tint
}

/// Pure, testable logic for the security add-ons lives in extensions of this namespace,
/// so names like `Base32` or `TOTP` can't clash with other parts of the app.
enum SecurityKit {}

// MARK: - Shared pieces

extension SecurityKit {
    /// Puts text on the clipboard, marked as concealed so clipboard managers skip it.
    /// Returns the clipboard's change count, to check later whether it still holds this text.
    @MainActor @discardableResult
    static func copy(_ text: String, concealed: Bool = false) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed {
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        return pb.changeCount
    }

    /// Opens a System Settings pane (`x-apple.systempreferences:` URL).
    @MainActor
    static func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// A small coloured dot with a soft glow, for "on / good / needs a look" states.
struct SecStatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 4)
    }
}

/// A selectable glass chip (used instead of toggles and segmented pickers, which snapshots can't draw).
struct SecChip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11).frame(height: 26)
            .foregroundStyle(selected ? .white : Tokens.secondary)
            .glassSurface(Capsule(), selected: selected, interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A slider drawn by hand, so layout snapshots show it.
struct SecSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 16
            let span = max(1, range.upperBound - range.lowerBound)
            let x = CGFloat(value - range.lowerBound) / CGFloat(span) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.surface2).frame(height: 4).padding(.horizontal, 8)
                Capsule().fill(tint.opacity(0.85)).frame(width: x + 8, height: 4).padding(.leading, 8)
                Circle().fill(.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = min(max((g.location.x - 8) / max(w, 1), 0), 1)
                let new = range.lowerBound + Int((t * CGFloat(span)).rounded())
                if new != value { value = new }
            })
        }
        .frame(height: 22)
    }
}
