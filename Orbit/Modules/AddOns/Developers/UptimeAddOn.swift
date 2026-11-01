import SwiftUI

/// Checks your sites every few minutes and tells you when one goes down or comes back.
@MainActor
@Observable
final class UptimeAddOn: AddOnModule {
    let id = "addon.uptime"
    let title = "Uptime"
    let symbol = "waveform.path.ecg"
    let addOn = AddOnInfo(category: .developers, tier: .pro,
                          summary: "Check your sites every few minutes and hear when one goes down.")

    struct Check: Codable, Equatable {
        let date: Date
        let status: Int?
        let ms: Int
        let up: Bool
    }

    struct Site: Codable, Identifiable, Equatable {
        var id = UUID()
        var url: String
        var history: [Check] = []
        var latest: Check? { history.last }
    }

    struct Saved: Codable {
        var sites: [Site] = []
        var minutes = 5
    }

    static let intervals = [1, 5, 15]

    private let ctx: AddOnContext
    private(set) var sites: [Site] = []
    var minutes = 5 {
        didSet { save(); if timer != nil { schedule() } }
    }
    private(set) var checking = false
    var draft = ""
    private var timer: Timer?

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        let saved = Storage.load(Saved.self, from: "addon-uptime") ?? Saved()
        sites = saved.sites
        minutes = Self.intervals.contains(saved.minutes) ? saved.minutes : 5
        if ModuleRegistry.isPreview { loadSample() }
    }

    func start() {
        schedule()
        checkAll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAll() }
        }
    }

    private func save() {
        guard !ModuleRegistry.isPreview else { return }
        Storage.save(Saved(sites: sites, minutes: minutes), to: "addon-uptime")
    }

    func add() {
        guard let url = UptimeMath.normalize(draft) else { return }
        draft = ""
        guard !sites.contains(where: { $0.url == url }) else { return }
        sites.append(Site(url: url))
        save()
        let newID = sites[sites.count - 1].id
        Task { await check(newID) }
    }

    func remove(_ id: UUID) {
        sites.removeAll { $0.id == id }
        save()
    }

    func checkAll() {
        guard !ModuleRegistry.isPreview, !checking else { return }
        checking = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for site in sites { group.addTask { await self.check(site.id) } }
            }
            checking = false
        }
    }

    private func check(_ id: UUID) async {
        guard let url = sites.first(where: { $0.id == id }).flatMap({ URL(string: $0.url) }) else { return }
        let result = await Self.probe(url)
        guard let i = sites.firstIndex(where: { $0.id == id }) else { return }
        let before = sites[i].latest?.up
        sites[i].history.append(result)
        if sites[i].history.count > 96 { sites[i].history.removeFirst(sites[i].history.count - 96) }
        save()
        notify(sites[i], UptimeMath.transition(previous: before, now: result.up))
    }

    /// One GET with a 10 s timeout. Up means a 2xx or 3xx answer.
    nonisolated static func probe(_ url: URL) async -> Check {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Orbit uptime check", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let started = Date.now
        do {
            let (_, response) = try await session.data(for: req)
            let ms = Int(Date.now.timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode
            return Check(date: started, status: code, ms: ms, up: UptimeMath.isUp(code))
        } catch {
            return Check(date: started, status: nil, ms: Int(Date.now.timeIntervalSince(started) * 1000), up: false)
        }
    }

    private func notify(_ site: Site, _ change: UptimeMath.Change?) {
        guard let change else { return }
        let host = UptimeMath.host(site.url)
        let url = site.url
        switch change {
        case .down:
            let why = site.latest?.status.map { "Answered \($0)" } ?? "No answer"
            ctx.alerts.post(NotchAlert(symbol: "exclamationmark.icloud.fill", tint: Tokens.error,
                                       title: "\(host) is down", subtitle: why,
                                       actions: [.init(title: "Later"), .init(title: "Open", isPrimary: true) { DevActions.open(url) }],
                                       duration: 8, sound: "Basso"))
        case .recovered:
            ctx.alerts.post(NotchAlert(symbol: "checkmark.icloud.fill", tint: Tokens.live,
                                       title: "\(host) is back up", subtitle: "Answered in \(site.latest?.ms ?? 0) ms",
                                       actions: [.init(title: "OK", isPrimary: true)], duration: 6))
        }
    }

    // MARK: Glances

    private var downSites: [Site] { sites.filter { $0.latest?.up == false } }

    var attention: Attention? {
        // Layout snapshots show the sample data, but shouldn't put it in every panel's status line.
        guard !ModuleRegistry.isPreview, let first = downSites.first, let check = first.latest else { return nil }
        let n = downSites.count
        return Attention(id: "uptime.\(first.id).\(check.date.timeIntervalSince1970)", symbol: "exclamationmark.icloud.fill",
                         tint: Tokens.error, label: n == 1 ? "Down" : "\(n) down", priority: 3,
                         headline: n == 1 ? "\(UptimeMath.host(first.url)) is down" : "\(n) sites are down")
    }

    var peekChip: PeekChip? {
        guard let first = downSites.first else { return nil }
        return PeekChip(symbol: "exclamationmark.icloud.fill", text: "\(UptimeMath.host(first.url)) down", tint: Tokens.error, priority: 3)
    }

    /// nil until a site has been checked, else how many are down.
    var downCount: Int? {
        sites.contains { $0.latest != nil } ? downSites.count : nil
    }

    var homeCard: AnyView? { AnyView(UptimeHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(UptimePanel(module: self)) }

    private func loadSample() {
        let now = Date.now
        func history(_ pattern: [Bool], base: Int) -> [Check] {
            pattern.enumerated().map { i, up in
                Check(date: now.addingTimeInterval(Double(i - pattern.count) * 300), status: up ? 200 : 503,
                      ms: base + (i * 37 % 90), up: up)
            }
        }
        let allUp = Array(repeating: true, count: 24)
        var blip = allUp; blip[15] = false; blip[16] = false
        var down = allUp; down[21] = false; down[22] = false; down[23] = false
        sites = [
            Site(url: "https://example.com", history: history(allUp, base: 120)),
            Site(url: "https://api.orbit.app/health", history: history(blip, base: 210)),
            Site(url: "https://staging.orbit.app", history: history(down, base: 340)),
        ]
        minutes = 5
    }
}

// MARK: - Maths (pure, tested)

enum UptimeMath {
    enum Change: Equatable { case down, recovered }

    static func isUp(_ status: Int?) -> Bool { status.map { (200..<400).contains($0) } ?? false }

    /// Only a change from a known state counts, so the first check never alerts.
    static func transition(previous: Bool?, now: Bool) -> Change? {
        guard let previous, previous != now else { return nil }
        return now ? .recovered : .down
    }

    /// Share of checks that were up, 0…100. Nil with no checks.
    static func uptimePercent(_ ups: [Bool]) -> Double? {
        guard !ups.isEmpty else { return nil }
        return Double(ups.filter { $0 }.count) / Double(ups.count) * 100
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 100 { return "100%" }
        return String(format: "%.1f%%", value)
    }

    /// Adds https:// when there's no scheme; nil when it isn't a web address.
    static func normalize(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        guard let url = URL(string: t), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return t
    }

    static func host(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let path = u.path == "/" ? "" : u.path
        return host.replacingOccurrences(of: "www.", with: "") + path
    }
}

// MARK: - Panel

private struct UptimePanel: View {
    @Bindable var module: UptimeAddOn

    var subtitle: String {
        let down = module.sites.filter { $0.latest?.up == false }.count
        if module.sites.isEmpty { return "Checks every \(module.minutes) min" }
        if down > 0 { return "\(down) down · checks every \(module.minutes) min" }
        return "All up · checks every \(module.minutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: "waveform.path.ecg", title: "Uptime", subtitle: subtitle, tint: AddOnCategory.developers.tint)
                if !module.sites.isEmpty {
                    // Orbit naps while everything's up and wakes with a start when a site goes down.
                    DevUptimeOrbit(size: 36, down: module.downCount)
                }
                HStack(spacing: 4) {
                    ForEach(UptimeAddOn.intervals, id: \.self) { m in
                        Button { module.minutes = m } label: {
                            Text("\(m)m").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(module.minutes == m ? .white : Tokens.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .glassSurface(Capsule(), selected: module.minutes == m, interactive: true)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).help("Check every \(m) min")
                    }
                }
                DevIconButton(symbol: "arrow.clockwise", help: "Check now") { module.checkAll() }
            }
            HStack(spacing: 8) {
                DevField(placeholder: "example.com or https://…", text: $module.draft) { module.add() }
                PillButton(title: "Add") { module.add() }
            }
            if module.sites.isEmpty {
                DevEmptyState(symbol: "waveform.path.ecg", title: "No sites yet",
                              message: "Add a web address and Orbit checks it every few minutes.",
                              art: AnyView(OrbitView(size: 60, mood: .happy, motion: .idle)))
            } else {
                NotchScroll {
                    VStack(spacing: 6) { ForEach(module.sites) { row($0) } }
                }
            }
        }
    }

    func row(_ site: UptimeAddOn.Site) -> some View {
        let last = site.latest
        let tint: Color = last == nil ? Tokens.faint : (last!.up ? Tokens.live : Tokens.error)
        let recent = Array(site.history.suffix(24))
        return HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(UptimeMath.host(site.url)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail(last)).font(.system(size: 11, design: .monospaced)).foregroundStyle(last?.up == false ? Tokens.error : Tokens.secondary)
            }
            Spacer(minLength: 6)
            Sparkline(checks: recent)
            Text(UptimeMath.percentText(UptimeMath.uptimePercent(site.history.map(\.up))))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 50, alignment: .trailing)
            Button { DevActions.open(site.url) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.secondary)
            }.buttonStyle(.plain).help("Open")
            Button { module.remove(site.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.faint)
            }.buttonStyle(.plain).help("Stop checking")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassCard(16)
    }

    func detail(_ check: UptimeAddOn.Check?) -> String {
        guard let check else { return "Not checked yet" }
        let code = check.status.map(String.init) ?? "no answer"
        return "\(code) · \(check.ms) ms · \(DevFormat.age(check.date) == "now" ? "just now" : DevFormat.age(check.date) + " ago")"
    }
}

/// The last 24 checks as tiny bars: height is response time, colour is up or down.
private struct Sparkline: View {
    let checks: [UptimeAddOn.Check]
    var body: some View {
        let slowest = max(checks.map(\.ms).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { i in
                let offset = i - (24 - checks.count)
                if offset >= 0 {
                    let c = checks[offset]
                    RoundedRectangle(cornerRadius: 1)
                        .fill(c.up ? Tokens.live.opacity(0.85) : Tokens.error)
                        .frame(width: 3, height: c.up ? max(4, 20 * CGFloat(c.ms) / CGFloat(slowest)) : 20)
                } else {
                    RoundedRectangle(cornerRadius: 1).fill(Tokens.surface2).frame(width: 3, height: 4)
                }
            }
        }
        .frame(height: 20, alignment: .bottom)
    }
}

/// Home: all up, or which site is down.
private struct UptimeHomeCard: View {
    let module: UptimeAddOn
    let open: () -> Void

    var body: some View {
        let down = module.sites.filter { $0.latest?.up == false }
        let last = module.sites.compactMap(\.latest?.date).max()
        let ago = last.map { DevFormat.age($0) == "now" ? "just now" : DevFormat.age($0) + " ago" }
        DevSecHomeCard(label: "Uptime", title: title(down), detail: detail(down, ago: ago),
                       titleTint: down.isEmpty ? .white : Tokens.error, open: open) {
            DevUptimeOrbit(size: 50, down: module.downCount, calm: true)
        }
    }

    private func title(_ down: [UptimeAddOn.Site]) -> String {
        let n = module.sites.count
        if n == 0 { return "No sites yet" }
        if down.count == 1 { return "\(UptimeMath.host(down[0].url)) is down" }
        if down.count > 1 { return "\(down.count) of \(n) sites down" }
        return module.downCount == nil ? "Not checked yet" : (n == 1 ? "Your site is up" : "All \(n) sites up")
    }

    private func detail(_ down: [UptimeAddOn.Site], ago: String?) -> String {
        if module.sites.isEmpty { return "Add a web address to keep an eye on" }
        if down.count == 1, let check = down[0].latest {
            return (check.status.map { "Answered \($0)" } ?? "No answer") + (ago.map { " · \($0)" } ?? "")
        }
        return "Every \(module.minutes) min" + (ago.map { " · checked \($0)" } ?? "")
    }
}
