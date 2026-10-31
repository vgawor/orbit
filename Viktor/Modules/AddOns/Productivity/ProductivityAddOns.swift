import SwiftUI

/// Productivity add-ons. Return each one here; they show up in Settings → Add-ons.
@MainActor
enum ProductivityAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [
            ClipboardAddOn(ctx),
            SnippetsAddOn(ctx),
            WorldClockAddOn(ctx),
            DayTimelineAddOn(ctx),
            CountdownsAddOn(ctx),
        ]
    }

    /// The tint every productivity add-on uses for its header icon.
    static var tint: Color { AddOnCategory.productivity.tint }
}

/// Small helpers shared by the productivity add-ons.
enum ProductivityFormat {
    /// "3h 20m", "45m", "2h". Negative or zero durations give "0m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "now", "2 min ago", "3 h ago", "yesterday", "4 days ago".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// A small round icon button used in add-on rows (pin, delete, edit).
struct ProductivityIconButton: View {
    let symbol: String
    var tint: Color = Tokens.secondary
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A rounded search / input field in the add-on look.
struct ProductivityField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String? = nil
    var onSubmit: () -> Void = {}
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Tokens.faint) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .glassSurface(Capsule())
    }
}
