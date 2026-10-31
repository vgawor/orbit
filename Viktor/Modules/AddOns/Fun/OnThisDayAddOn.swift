import AppKit
import SwiftUI

/// The pure part of "On this day": Wikipedia's feed URL, parsing and day keys.
enum OnThisDayLogic {
    struct Event: Codable, Equatable, Identifiable {
        let year: Int
        let text: String
        var title: String?
        var url: URL?
        var id: String { "\(year)·\(text)" }

        var yearText: String { year < 0 ? "\(-year) BC" : "\(year)" }
    }

    /// "10-28" for 28 October; one cache entry per day of the year.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", c.month ?? 1, c.day ?? 1)
    }

    static func feedURL(for date: Date, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.month, .day], from: date)
        let path = String(format: "%02d/%02d", c.month ?? 1, c.day ?? 1)
        return URL(string: "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/selected/\(path)")!
    }

    private struct Feed: Decodable {
        struct Item: Decodable {
            struct Page: Decodable {
                struct Titles: Decodable { let normalized: String? }
                struct URLs: Decodable {
                    struct Desktop: Decodable { let page: URL? }
                    let desktop: Desktop?
                }
                let titles: Titles?
                let normalizedtitle: String?
                let content_urls: URLs?
            }
            let text: String?
            let year: Int?
            let pages: [Page]?
        }
        let selected: [Item]?
    }

    /// Reads the feed's events, keeping ones with a year and some text. Newest first.
    static func parse(_ data: Data) throws -> [Event] {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        return (feed.selected ?? []).compactMap { item in
            guard let year = item.year, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let page = item.pages?.first
            return Event(year: year, text: text,
                         title: page?.titles?.normalized ?? page?.normalizedtitle,
                         url: page?.content_urls?.desktop?.page)
        }
        .sorted { $0.year > $1.year }
    }

    /// The events shown together, starting at `index` and wrapping round.
    static func window(_ events: [Event], from index: Int, count: Int) -> [Event] {
        guard !events.isEmpty else { return [] }
        let n = min(count, events.count)
        return (0..<n).map { events[((index + $0) % events.count + events.count) % events.count] }
    }

    /// Keeps the cache small: the most recent `limit` days by key, always including `keep`.
    static func pruned(_ days: [String: [Event]], keep: String, limit: Int = 7) -> [String: [Event]] {
        guard days.count > limit else { return days }
        var kept = days.filter { $0.key == keep }
        for key in days.keys.sorted().reversed() where kept.count < limit && key != keep { kept[key] = days[key] }
        return kept
    }

    static let sample: [Event] = [
        Event(year: 1971, text: "Britain launched its first satellite, Prospero, on a Black Arrow rocket from Australia.", title: "Prospero (satellite)",
              url: URL(string: "https://en.wikipedia.org/wiki/Prospero_(satellite)")),
        Event(year: 1886, text: "The Statue of Liberty was dedicated in New York Harbor.", title: "Statue of Liberty",
              url: URL(string: "https://en.wikipedia.org/wiki/Statue_of_Liberty")),
        Event(year: 1636, text: "Harvard College was founded by a vote of the Great and General Court of Massachusetts Bay.", title: "Harvard University",
              url: URL(string: "https://en.wikipedia.org/wiki/Harvard_University")),
        Event(year: 1492, text: "Christopher Columbus landed in Cuba on his first voyage.", title: "Voyages of Christopher Columbus",
              url: URL(string: "https://en.wikipedia.org/wiki/Voyages_of_Christopher_Columbus")),
    ]
}

/// On this day: a few things that happened on today's date, from Wikipedia.
@MainActor
@Observable
final class OnThisDayAddOn: AddOnModule {
    let id = "addon.onthisday"
    let title = "On this day"
    let symbol = "calendar.badge.clock"
    let addOn = AddOnInfo(category: .fun, tier: .free,
                          summary: "A few moments from history that happened on today's date.")

    enum Status: Equatable { case idle, loading, failed }

    private struct Saved: Codable { var days: [String: [OnThisDayLogic.Event]] }

    private(set) var days: [String: [OnThisDayLogic.Event]]
    private(set) var status = Status.idle
    private(set) var index = 0
    private var timer: Timer?
    private var loadingKey: String?
    private let openPanel: @MainActor (String) -> Void

    init(openPanel: @escaping @MainActor (String) -> Void) {
        self.openPanel = openPanel
        days = Storage.load(Saved.self, from: "addon-onthisday")?.days ?? [:]
        if ModuleRegistry.isPreview { days[OnThisDayLogic.dayKey(for: .now)] = OnThisDayLogic.sample }
    }

    var todayKey: String { OnThisDayLogic.dayKey(for: .now) }
    var events: [OnThisDayLogic.Event] { days[todayKey] ?? [] }
    var shown: [OnThisDayLogic.Event] { OnThisDayLogic.window(events, from: index, count: 4) }

    func start() {
        loadIfNeeded()
        timer?.invalidate()
        // Check once an hour so a new day brings new events.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadIfNeeded() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func another() {
        guard !events.isEmpty else { return }
        withAnimation(Tokens.spring) { index = (index + 1) % events.count }
    }

    func feature(_ event: OnThisDayLogic.Event) {
        guard let i = events.firstIndex(of: event) else { return }
        withAnimation(Tokens.spring) { index = i }
    }

    func loadIfNeeded() {
        guard events.isEmpty, !ModuleRegistry.isPreview else { return }
        Task { await load() }
    }

    func load() async {
        let key = todayKey
        guard loadingKey != key else { return }
        loadingKey = key
        defer { loadingKey = nil }
        status = .loading
        var req = URLRequest(url: OnThisDayLogic.feedURL(for: .now), timeoutInterval: 15)
        req.setValue("Orbit-notch-app/1.0 (macOS notch app; On this day add-on)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { status = .failed; return }
            let list = try OnThisDayLogic.parse(data)
            guard !list.isEmpty else { status = .failed; return }
            days[key] = list
            days = OnThisDayLogic.pruned(days, keep: key)
            index = 0
            status = .idle
            Storage.save(Saved(days: days), to: "addon-onthisday")
        } catch {
            status = .failed
        }
    }

    func open(_ event: OnThisDayLogic.Event) {
        guard let url = event.url else { return }
        NSWorkspace.shared.open(url)
    }

    var homeCard: AnyView? {
        guard let event = shown.first else { return nil }
        return AnyView(Button { self.openPanel(self.id) } label: {
            NotchCard {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel("On this day")
                        Text(event.yearText).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Color.funTint)
                            .monospacedDigit()
                        Text(event.text).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    FunPropOrbit(prop: .scroll, size: 48).padding(.top, 6).padding(.trailing, 8)
                }
            }
        }
        .buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(OnThisDayPanel(model: self)) }
}

// MARK: - Views

private struct OnThisDayPanel: View {
    let model: OnThisDayAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "calendar.badge.clock", title: "On this day",
                            subtitle: Date.now.formatted(.dateTime.day().month(.wide)), tint: .funTint)
                if !model.events.isEmpty {
                    Text("\(model.index + 1) of \(model.events.count)")
                        .font(.system(size: 11)).foregroundStyle(Tokens.faint).monospacedDigit()
                }
            }
            if let first = model.shown.first {
                featured(first)
                if model.shown.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        CardLabel("Also on this day").padding(.leading, 4).padding(.bottom, 4)
                        ForEach(model.shown.dropFirst()) { event in
                            Button { model.feature(event) } label: { row(event) }.buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .glassCard(22)
                }
            } else {
                empty
            }
        }
        .onAppear { model.loadIfNeeded() }
    }

    private func featured(_ event: OnThisDayLogic.Event) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.yearText)
                    .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.funTint)
                    .monospacedDigit()
                Text(yearsAgo(event)).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                Spacer()
                FunPropOrbit(prop: .scroll, size: 58).padding(.trailing, 10).padding(.top, -4).frame(height: 34)
            }
            Text(event.text)
                .font(.system(size: 15))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if event.url != nil {
                    GlassPillButton(title: "Read more", symbol: "arrow.up.right") { model.open(event) }
                }
                Spacer()
                PillButton(title: "Another") { model.another() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
        .id(event.id)
        .transition(.opacity)
    }

    private func row(_ event: OnThisDayLogic.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(event.yearText)
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.funTint)
                .frame(width: 52, alignment: .leading)
            Text(event.text)
                .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func yearsAgo(_ event: OnThisDayLogic.Event) -> String {
        let now = Calendar.current.component(.year, from: .now)
        let ago = now - event.year
        return ago <= 0 ? "This year" : ago == 1 ? "1 year ago" : "\(ago) years ago"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if model.status == .loading {
                FunPropOrbit(prop: .scroll, size: 60, motion: .thinking)
                Text("Orbit is looking back in time…").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
            } else {
                FunPropOrbit(prop: .scroll, size: 60, motion: .still, mood: .squint)
                Text("History is out of reach right now.").font(.system(size: 14, weight: .medium))
                Text("Check your connection and try again.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                GlassPillButton(title: "Try again", symbol: "arrow.clockwise") { Task { await model.load() } }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }
}
