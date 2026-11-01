import SwiftUI

/// Personal look-and-feel choices (Settings → Appearance). Saved in UserDefaults.
@MainActor
@Observable
final class Appearance {
    static let shared: Appearance = {
        let a = Appearance()
        a.addNewWidgets()
        return a
    }()

    enum MusicStyle: String, CaseIterable { case vinyl = "Vinyl", cover = "Cover" }
    enum HomeLayout: String, CaseIterable { case feed = "Feed", compact = "Compact" }
    enum PanelStyle: String, CaseIterable { case glass = "Glass", solid = "Solid black" }

    /// The widgets of the Home feed, in their default order.
    enum Widget: String, CaseIterable, Identifiable {
        case greeting, brief, shortcuts, glance, now, bots, agents, media, numbers, photos
        var id: String { rawValue }
        var name: String {
            switch self {
            case .greeting: "Greeting"
            case .brief: "Morning brief (Claude)"
            case .shortcuts: "Shortcuts"
            case .glance: "Time, date and countdown"
            case .now: "Now & next (meetings, tasks)"
            case .bots: "Bots (requests, reports, who's working)"
            case .agents: "Agents (sessions, usage)"
            case .media: "Music and Focus"
            case .numbers: "Task numbers"
            case .photos: "Photo slideshow"
            }
        }
    }

    /// Orbit's colours (Settings → Appearance). Ids are kept from the old Dot colours so saved choices carry over.
    struct Companion: Identifiable, Hashable {
        let id: String
        let name: String
        let body: Color
        let ring: Color
        let eyes: Color
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let companions: [Companion] = [
        .init(id: "dot", name: "White", body: .white, ring: hex(0xB9B6D3), eyes: hex(0x16131F)),
        .init(id: "original", name: "Original", body: hex(0xFBAE72), ring: hex(0xA196FC), eyes: hex(0x3B0844)),
        .init(id: "ink", name: "Ink", body: hex(0x26252C), ring: hex(0x77748A), eyes: .white),
        .init(id: "bluey", name: "Bluey", body: hex(0x5C9EFF), ring: hex(0xCFE1FF), eyes: hex(0x0A1A33)),
        .init(id: "coral", name: "Coral", body: hex(0xFF7A6B), ring: hex(0xFFD3CB), eyes: hex(0x2A0A06)),
        .init(id: "mint", name: "Mint", body: hex(0x6FE3B0), ring: hex(0x2E8F68), eyes: hex(0x06281B)),
        .init(id: "sunny", name: "Sunny", body: hex(0xFFD34D), ring: hex(0xFF9F43), eyes: hex(0x2B1E00)),
    ]
    static func companion(_ id: String) -> Companion { companions.first { $0.id == id } ?? companions[0] }

    var musicStyle = MusicStyle(rawValue: UserDefaults.standard.string(forKey: "look.music") ?? "") ?? .vinyl {
        didSet { UserDefaults.standard.set(musicStyle.rawValue, forKey: "look.music") }
    }
    /// Liquid Glass panel (default) or the original solid black.
    var panelStyle = PanelStyle(rawValue: UserDefaults.standard.string(forKey: "look.panel") ?? "") ?? .glass {
        didSet { UserDefaults.standard.set(panelStyle.rawValue, forKey: "look.panel") }
    }
    var homeLayout = HomeLayout(rawValue: UserDefaults.standard.string(forKey: "look.home") ?? "") ?? .feed {
        didSet { UserDefaults.standard.set(homeLayout.rawValue, forKey: "look.home") }
    }
    /// Which modules get a card on Home, in order (max 4). Empty = the first four that have one.
    var homeCards: [String] = UserDefaults.standard.stringArray(forKey: "look.homeCards") ?? [] {
        didSet { UserDefaults.standard.set(homeCards, forKey: "look.homeCards") }
    }
    /// Home feed widgets in order; hidden ones are left out. Photos is off by default.
    var homeWidgets: [String] = UserDefaults.standard.stringArray(forKey: "look.widgets")
        ?? Widget.allCases.filter { $0 != .photos }.map(\.rawValue) {
        didSet { UserDefaults.standard.set(homeWidgets, forKey: "look.widgets") }
    }
    var widgets: [Widget] { homeWidgets.compactMap(Widget.init(rawValue:)) }

    /// Add-ons whose Home widget you've hidden (every add-on you add shows its widget by default).
    var hiddenAddOnWidgets: [String] = UserDefaults.standard.stringArray(forKey: "look.hiddenAddOnWidgets") ?? [] {
        didSet { UserDefaults.standard.set(hiddenAddOnWidgets, forKey: "look.hiddenAddOnWidgets") }
    }

    // MARK: Your own Home: order and sizes

    /// How wide a Home widget is: a third, half or the full width.
    enum HomeSize: String, CaseIterable, Identifiable {
        case third, half, full
        var id: String { rawValue }
        var fraction: Double {
            switch self {
            case .third: 1.0 / 3
            case .half: 0.5
            case .full: 1
            }
        }
        var label: String {
            switch self {
            case .third: "Small"
            case .half: "Medium"
            case .full: "Wide"
            }
        }
        var symbol: String {
            switch self {
            case .third: "square"
            case .half: "rectangle"
            case .full: "rectangle.split.3x1"
            }
        }
    }

    /// Where a widget sits on the Home canvas: x and width as parts of the width (0…1), y and
    /// height in points. Snapped to a grid so things line up.
    struct HomeFrame: Codable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        nonisolated static let columns = 24.0
        nonisolated static let rowStep = 8.0
        nonisolated static let minWidth = 1.0 / 6
        nonisolated static let minHeight = 40.0

        /// Snapped to the grid, at least the minimum size, and inside the canvas.
        func snapped() -> HomeFrame {
            let w = max(Self.minWidth, min(1, (self.w * Self.columns).rounded() / Self.columns))
            let x = max(0, min(1 - w, (self.x * Self.columns).rounded() / Self.columns))
            let h = max(Self.minHeight, (self.h / Self.rowStep).rounded() * Self.rowStep)
            let y = max(0, (self.y / Self.rowStep).rounded() * Self.rowStep)
            return HomeFrame(x: x, y: y, w: w, h: h)
        }
    }

    /// Lays widgets out so none overlap, like a dashboard: the one you just moved gets its spot,
    /// anything in its way moves down, then everything floats up to close gaps. Widgets keep their
    /// column and size; the order top to bottom follows where they are. Pure, so it's easy to test.
    nonisolated static func resolve(_ frames: [String: HomeFrame], moved: String? = nil, gap: Double = 10) -> [String: HomeFrame] {
        func sideBySide(_ a: HomeFrame, _ b: HomeFrame) -> Bool {
            a.x < b.x + b.w - 0.001 && b.x < a.x + a.w - 0.001
        }
        // Top to bottom. The moved widget goes before a widget when dropped on its top half.
        let order = frames.keys.sorted { a, b in
            let fa = frames[a]!, fb = frames[b]!
            if a == moved { return fa.y < fb.y + fb.h / 2 }
            if b == moved { return !(fb.y < fa.y + fa.h / 2) }
            return (fa.y, fa.x, a) < (fb.y, fb.x, b)
        }
        var placed: [String: HomeFrame] = [:]
        for key in order {
            var f = frames[key]!
            // Float up as far as possible without landing on anything already placed.
            f.y = 0
            var moving = true
            while moving {
                moving = false
                for other in placed.values where sideBySide(f, other) && f.y < other.y + other.h + gap && other.y < f.y + f.h + gap {
                    f.y = other.y + other.h + gap
                    moving = true
                }
            }
            placed[key] = f
        }
        return placed
    }

    /// Each widget's place on Home, by key. Widgets without one are placed at the bottom.
    var homeFrames: [String: HomeFrame] = (UserDefaults.standard.data(forKey: "look.homeFrames"))
        .flatMap { try? JSONDecoder().decode([String: HomeFrame].self, from: $0) } ?? [:] {
        didSet { if let data = try? JSONEncoder().encode(homeFrames) { UserDefaults.standard.set(data, forKey: "look.homeFrames") } }
    }

    /// Brings a widget to the front (the last one you moved is on top).
    func bringToFront(_ key: String) { homeOrder = homeOrder.filter { $0 != key } + [key] }

    /// Every Home widget's place, as keys: built-in widget names, or "addon:<id>" for add-ons.
    var homeOrder: [String] = UserDefaults.standard.stringArray(forKey: "look.homeOrder") ?? [] {
        didSet { UserDefaults.standard.set(homeOrder, forKey: "look.homeOrder") }
    }
    var homeSizes: [String: String] = UserDefaults.standard.dictionary(forKey: "look.homeSizes") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(homeSizes, forKey: "look.homeSizes") }
    }

    func size(of key: String) -> HomeSize {
        if let saved = homeSizes[key].flatMap(HomeSize.init(rawValue:)) { return saved }
        // Add-ons and Bots start at half width; the built-in rows are designed for the full width.
        return key.hasPrefix("addon:") || key == Widget.bots.rawValue ? .half : .full
    }

    func setSize(_ size: HomeSize, of key: String) { homeSizes[key] = size.rawValue }

    /// The shown widgets in your order; ones you haven't placed keep their default order at the end.
    nonisolated static func ordered(_ keys: [String], by order: [String]) -> [String] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.enumerated().sorted { a, b in
            (rank[a.element] ?? Int.max, a.offset) < (rank[b.element] ?? Int.max, b.offset)
        }.map(\.element)
    }

    /// Drag on Home: puts `key` where `target` is, among the widgets shown now.
    func moveHome(_ key: String, to target: String, shown: [String]) {
        var order = Self.ordered(shown, by: homeOrder)
        guard key != target, let from = order.firstIndex(of: key), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(key, at: to)
        // Keep hidden widgets' places too, after the shown ones.
        homeOrder = order + homeOrder.filter { !order.contains($0) }
    }

    /// Adds widgets introduced in later versions once, so existing Home setups get them too.
    func addNewWidgets() {
        if !UserDefaults.standard.bool(forKey: "look.botsAdded") {
            UserDefaults.standard.set(true, forKey: "look.botsAdded")
            if !homeWidgets.contains("bots") {
                let at = (homeWidgets.firstIndex(of: "now").map { $0 + 1 }) ?? homeWidgets.count
                homeWidgets.insert("bots", at: at)
            }
        }
        guard !UserDefaults.standard.bool(forKey: "look.briefAdded") else { return }
        UserDefaults.standard.set(true, forKey: "look.briefAdded")
        if !homeWidgets.contains("brief") {
            let at = (homeWidgets.firstIndex(of: "greeting").map { $0 + 1 }) ?? 0
            homeWidgets.insert("brief", at: at)
        }
    }

    /// Shortcut tiles: app paths or web links.
    var shortcuts: [String] = UserDefaults.standard.stringArray(forKey: "look.shortcuts") ?? Appearance.defaultShortcuts() {
        didSet { UserDefaults.standard.set(shortcuts, forKey: "look.shortcuts") }
    }

    /// A date to count down to ("14 days to Launch day"). Empty title = use the next task due.
    var countdownTitle = UserDefaults.standard.string(forKey: "look.countdownTitle") ?? "" {
        didSet { UserDefaults.standard.set(countdownTitle, forKey: "look.countdownTitle") }
    }
    var countdownDate = (UserDefaults.standard.object(forKey: "look.countdownDate") as? Date) ?? .now.addingTimeInterval(14 * 86400) {
        didSet { UserDefaults.standard.set(countdownDate, forKey: "look.countdownDate") }
    }

    /// Apps you likely use, if installed, plus HubSpot on the web.
    static func defaultShortcuts() -> [String] {
        let candidates = ["/Applications/Microsoft Teams.app", "/Applications/zoom.us.app", "/Applications/Spotify.app",
                          "/System/Applications/Calendar.app", "/System/Applications/Mail.app", "/Applications/Google Chrome.app",
                          "/Applications/Safari.app"]
        // HubSpot only for people who use it (connected in Settings → Accounts).
        var list = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        if UserDefaults.standard.string(forKey: "hubspot.email")?.isEmpty == false { list.append("https://app.hubspot.com") }
        return Array(list.prefix(6))
    }

    var companionID = UserDefaults.standard.string(forKey: "look.companion") ?? "dot" {
        didSet { UserDefaults.standard.set(companionID, forKey: "look.companion") }
    }
    /// The name in the greeting ("Morning, Sam").
    var greetingName = UserDefaults.standard.string(forKey: "look.name") ?? (NSFullUserName().split(separator: " ").first.map(String.init) ?? "") {
        didSet { UserDefaults.standard.set(greetingName, forKey: "look.name") }
    }

    var companion: Companion { Self.companions.first { $0.id == companionID } ?? Self.companions[0] }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        let part = h < 12 ? "Morning" : h < 18 ? "Afternoon" : "Evening"
        let name = greetingName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? part : "\(part), \(name)"
    }
}
