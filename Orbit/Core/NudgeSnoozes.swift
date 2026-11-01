import Foundation
import Observation

/// How long to keep Orbit quiet about something.
enum SnoozeOption: String, CaseIterable, Identifiable {
    case hour, tomorrow, untilChanged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "1 hour"
        case .tomorrow: "Until tomorrow"
        case .untilChanged: "Until it changes"
        }
    }

    /// When the snooze ends. "Until tomorrow" is 08:00 the next day. "Until it changes" never
    /// ends by itself: it lasts until the thing itself changes (a new overdue task gives a new id).
    func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(byAdding: .hour, value: 8, to: tomorrow) ?? tomorrow
        case .untilChanged:
            return .distantFuture
        }
    }
}

/// Snoozed nudges, by attention id. Saved, so a snooze survives a restart.
@MainActor
@Observable
final class NudgeSnoozes {
    static let shared = NudgeSnoozes()

    private(set) var until: [String: Date] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "nudgeSnoozes"
    /// Enough for any real use; the oldest go first.
    static let limit = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        until = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func isSnoozed(_ id: String, now: Date = .now) -> Bool {
        guard let end = until[id] else { return false }
        return end > now
    }

    func snooze(_ id: String, _ option: SnoozeOption, now: Date = .now) {
        until[id] = option.until(from: now)
        save(now: now)
    }

    func wake(_ id: String) {
        until[id] = nil
        save(now: .now)
    }

    func wakeAll() {
        until = [:]
        save(now: .now)
    }

    /// True if anything is snoozed right now.
    func hasActive(now: Date = .now) -> Bool { until.values.contains { $0 > now } }

    private func save(now: Date) {
        var kept = until.filter { $0.value > now }
        if kept.count > Self.limit {
            for (id, _) in kept.sorted(by: { $0.value < $1.value }).prefix(kept.count - Self.limit) { kept[id] = nil }
        }
        until = kept
        defaults.set(kept.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
