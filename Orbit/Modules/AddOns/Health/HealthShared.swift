import AppKit
import SwiftUI

// Small pieces shared by the Health add-ons: day keys, idle time, durations and a few views.

/// Days are stored as "yyyy-MM-dd" keys in the user's calendar.
enum HealthDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last `count` days, ending with `now`'s day, oldest first (start of each day).
    static func lastDays(_ count: Int, from now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(count, 0)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    static func lastKeys(_ count: Int, from now: Date = .now, calendar: Calendar = .current) -> [String] {
        lastDays(count, from: now, calendar: calendar).map { key($0, calendar: calendar) }
    }

    /// Keeps only the entries of the last `days` days.
    static func prune<V>(_ dict: [String: V], keep days: Int, now: Date = .now, calendar: Calendar = .current) -> [String: V] {
        let keep = Set(lastKeys(days, from: now, calendar: calendar))
        return dict.filter { keep.contains($0.key) }
    }

    /// One letter for a weekday, e.g. "M".
    static func letter(_ date: Date, calendar: Calendar = .current) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let i = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(i) ? symbols[i] : ""
    }
}

/// How long the Mac has had no keyboard or mouse input. Needs no permission.
enum HealthIdle {
    /// Away longer than this counts as idle.
    static let threshold: TimeInterval = 120

    static func seconds() -> TimeInterval {
        if let any = CGEventType(rawValue: UInt32.max) {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        }
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    static func isIdle(_ seconds: TimeInterval) -> Bool { seconds > threshold }
}

enum HealthDuration {
    /// "2h 05m", "12m", "45s".
    static func short(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        if s < 60 { return "\(s)s" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }
}

// MARK: - Views

/// A progress ring.
struct HealthRing: View {
    let progress: Double
    var tint: Color = .white
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// "−  value  +" in a glass capsule.
struct HealthStepper: View {
    let label: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                button("minus", minus)
                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 52)
                button("plus", plus)
            }
            .glassSurface(Capsule())
        }
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An on/off switch that draws in snapshots too.
struct HealthSwitch: View {
    let label: String
    let isOn: Bool
    var tint: Color = Tokens.live
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                Spacer(minLength: 4)
                Capsule().fill(isOn ? tint : Color.white.opacity(0.14))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Tokens.spring, value: isOn)
    }
}

/// Little vertical bars for the last few days, today brightest.
struct HealthBars: View {
    struct Bar: Identifiable {
        var id: String { key }
        let key: String
        let letter: String
        let value: Double
    }
    let bars: [Bar]
    var tint: Color = .white
    /// Draws a dashed line at this value (e.g. a daily goal).
    var goal: Double? = nil
    var height: CGFloat = 70

    var body: some View {
        let top = max(bars.map(\.value).max() ?? 0, goal ?? 0, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                let isToday = i == bars.count - 1
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tint.opacity(isToday ? 1 : 0.5))
                            .frame(height: bar.value > 0 ? max(4, height * bar.value / top) : 0)
                    }
                    .frame(height: height)
                    Text(bar.letter).font(.system(size: 10, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? .white : Tokens.faint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let goal, goal > 0 {
                Rectangle().fill(.clear).frame(height: 1)
                    .overlay(Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Tokens.faint))
                    .offset(y: height - height * goal / top)
            }
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(); p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return p
        }
    }
}

/// A round glass icon button.
struct HealthIconButton: View {
    let symbol: String
    var size: CGFloat = 30
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: size, height: size)
                .glassSurface(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
