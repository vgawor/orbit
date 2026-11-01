import SwiftUI

/// One thing on the watchlist: a crypto coin (CoinGecko id) or a currency pair ("EUR/SEK").
struct WatchItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case coin, pair }
    let kind: Kind
    /// CoinGecko id ("bitcoin") or pair ("EUR/SEK").
    let key: String
    var id: String { "\(kind.rawValue):\(key)" }

    static func coin(_ id: String) -> WatchItem { WatchItem(kind: .coin, key: id) }
    static func pair(_ p: String) -> WatchItem { WatchItem(kind: .pair, key: p) }

    var pairCodes: (String, String)? {
        let parts = key.split(separator: "/").map(String.init)
        return kind == .pair && parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    var name: String { kind == .coin ? (Watchlist.coins.first { $0.id == key }?.name ?? key.capitalized) : key }
    var short: String { kind == .coin ? (Watchlist.coins.first { $0.id == key }?.symbol ?? key.uppercased()) : key }
}

/// A price and its change over about a day.
struct WatchQuote: Codable, Equatable {
    var price: Double
    var change: Double?
    var currency: String
}

enum Watchlist {
    struct Coin { let id: String; let symbol: String; let name: String }
    static let coins: [Coin] = [
        .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin"), .init(id: "ethereum", symbol: "ETH", name: "Ethereum"),
        .init(id: "solana", symbol: "SOL", name: "Solana"), .init(id: "ripple", symbol: "XRP", name: "XRP"),
        .init(id: "binancecoin", symbol: "BNB", name: "BNB"), .init(id: "cardano", symbol: "ADA", name: "Cardano"),
        .init(id: "dogecoin", symbol: "DOGE", name: "Dogecoin"), .init(id: "polkadot", symbol: "DOT", name: "Polkadot"),
        .init(id: "litecoin", symbol: "LTC", name: "Litecoin"), .init(id: "chainlink", symbol: "LINK", name: "Chainlink"),
        .init(id: "avalanche-2", symbol: "AVAX", name: "Avalanche"), .init(id: "tron", symbol: "TRX", name: "TRON"),
    ]
    static let pairs = ["EUR/SEK", "USD/SEK", "GBP/SEK", "NOK/SEK", "DKK/SEK", "CHF/SEK", "EUR/USD", "GBP/USD", "USD/JPY", "EUR/NOK"]
    static let currencies = ["SEK", "EUR", "USD", "GBP", "NOK", "DKK"]

    static func coinGeckoURL(ids: [String], currency: String) -> URL {
        let vs = currency.lowercased()
        return URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids.joined(separator: ","))&vs_currencies=\(vs)&include_24hr_change=true")!
    }

    /// CoinGecko `simple/price` → quotes by coin id.
    static func parseCoinGecko(_ data: Data, currency: String) -> [String: WatchQuote] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        let vs = currency.lowercased()
        var out: [String: WatchQuote] = [:]
        for (id, values) in json {
            guard let price = (values[vs] as? NSNumber)?.doubleValue else { continue }
            out[id] = WatchQuote(price: price, change: (values["\(vs)_24h_change"] as? NSNumber)?.doubleValue, currency: currency.uppercased())
        }
        return out
    }

    /// A pair's rate on the last day and its change from the day before.
    static func pairQuote(_ pair: (String, String), days: [FXRates]) -> WatchQuote? {
        guard let last = days.last, let now = last.cross(pair.0, pair.1) else { return nil }
        var change: Double?
        if days.count >= 2, let before = days[days.count - 2].cross(pair.0, pair.1), before > 0 {
            change = (now / before - 1) * 100
        }
        return WatchQuote(price: now, change: change, currency: pair.1)
    }
}

/// The overall direction of the list, which Orbit's face follows: happy when it's up, wide-eyed when it's down.
struct MarketMood: Equatable {
    enum Direction: Equatable { case up, flat, down, unknown }
    let direction: Direction
    /// Average change in percent, nil when nothing has a change yet.
    let average: Double?

    /// Moves under a quarter of a percent count as flat.
    static func of(_ changes: [Double]) -> MarketMood {
        guard !changes.isEmpty else { return MarketMood(direction: .unknown, average: nil) }
        let avg = changes.reduce(0, +) / Double(changes.count)
        let dir: Direction = avg >= 0.25 ? .up : avg <= -0.25 ? .down : .flat
        return MarketMood(direction: dir, average: avg)
    }

    var orbit: FinanceOrbit {
        switch direction {
        case .up: (average ?? 0) >= 3 ? FinanceOrbit(mood: .happy, motion: .celebrate) : .happy
        case .flat, .unknown: .calm
        case .down: (average ?? 0) <= -3 ? FinanceOrbit(mood: .wide, motion: .alert, tint: Tokens.error)
                                         : FinanceOrbit(mood: .wide, motion: .idle)
        }
    }

    var line: String {
        let avg = average.map { " · " + Money.change($0) + " on average" } ?? ""
        switch direction {
        case .up: return "Up overall" + avg
        case .down: return "Down overall" + avg
        case .flat: return "Pretty calm" + avg
        case .unknown: return "Waiting for prices"
        }
    }

    var tint: Color {
        switch direction {
        case .up: Tokens.live
        case .down: Tokens.error
        case .flat, .unknown: Tokens.secondary
        }
    }
}

/// Market watchlist: crypto (CoinGecko) and currency pairs (ECB). Information only, no advice.
@MainActor
@Observable
final class WatchlistAddOn: AddOnModule {
    let id = "addon.watchlist"
    let title = "Watchlist"
    let symbol = "chart.line.uptrend.xyaxis"
    let addOn = AddOnInfo(category: .finance, tier: .pro,
                          summary: "Follow Bitcoin, Ethereum and currency pairs like EUR/SEK, updated every 5 minutes.")

    struct Saved: Codable {
        var items: [WatchItem] = [.coin("bitcoin"), .coin("ethereum"), .pair("EUR/SEK"), .pair("USD/SEK")]
        var currency = "SEK"
        var quotes: [String: WatchQuote] = [:]
        var updated: Date?
    }

    private static let file = "addon-watchlist"
    private(set) var items: [WatchItem]
    var currency: String { didSet { if oldValue != currency { save(); Task { await refresh() } } } }
    private(set) var quotes: [String: WatchQuote]
    private(set) var updated: Date?
    private(set) var loading = false
    private(set) var error: String?
    var editing = false
    private var timer: Timer?
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        var saved = Storage.load(Saved.self, from: Self.file) ?? Saved()
        if ModuleRegistry.isPreview, saved.quotes.isEmpty {
            saved.quotes = [
                "coin:bitcoin": .init(price: 1_084_230, change: 2.31, currency: "SEK"),
                "coin:ethereum": .init(price: 41_870, change: -1.12, currency: "SEK"),
                "pair:EUR/SEK": .init(price: 11.2134, change: 0.18, currency: "SEK"),
                "pair:USD/SEK": .init(price: 10.3821, change: -0.42, currency: "SEK"),
            ]
            saved.updated = .now
        }
        items = saved.items; currency = saved.currency; quotes = saved.quotes; updated = saved.updated
    }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshInBackground() { Task { await refresh() } }

    func refresh() async {
        guard !ModuleRegistry.isPreview, !loading else { return }
        loading = true
        defer { loading = false }
        var fresh = quotes, problems: [String] = []
        let coinIDs = items.filter { $0.kind == .coin }.map(\.key)
        if !coinIDs.isEmpty {
            do {
                let data = try await FinanceNet.get(Watchlist.coinGeckoURL(ids: coinIDs, currency: currency))
                for (id, q) in Watchlist.parseCoinGecko(data, currency: currency) { fresh["coin:\(id)"] = q }
            } catch { problems.append((error as? LocalizedError)?.errorDescription ?? "Crypto prices unavailable.") }
        }
        let pairs = items.compactMap { item in item.pairCodes.map { (item, $0) } }
        if !pairs.isEmpty {
            do {
                let days = try await Frankfurter.lastTwoDays()
                for (item, codes) in pairs { if let q = Watchlist.pairQuote(codes, days: days) { fresh[item.id] = q } }
            } catch { problems.append((error as? LocalizedError)?.errorDescription ?? "Currency rates unavailable.") }
        }
        quotes = fresh
        if problems.isEmpty { updated = .now }
        error = problems.first
        save()
    }

    func toggle(_ item: WatchItem) {
        if let i = items.firstIndex(of: item) { items.remove(at: i) } else { items.append(item) }
        save()
        Task { await refresh() }
    }

    func remove(_ item: WatchItem) { items.removeAll { $0 == item }; save() }

    /// The latest quote, if it's in the chosen currency (crypto) or a pair.
    func quote(_ item: WatchItem) -> WatchQuote? {
        guard let q = quotes[item.id] else { return nil }
        return item.kind == .coin && q.currency != currency ? nil : q
    }

    var mood: MarketMood { MarketMood.of(items.compactMap { quote($0)?.change }) }

    private func save() {
        Storage.save(Saved(items: items, currency: currency, quotes: quotes, updated: updated), to: Self.file)
    }

    var peekChip: PeekChip? {
        guard let first = items.first, let q = quote(first) else { return nil }
        let tint = (q.change ?? 0) >= 0 ? Tokens.live : Tokens.error
        let change = q.change.map { " " + Money.change($0) } ?? ""
        return PeekChip(symbol: symbol, text: "\(first.short) \(Money.price(q.price, q.currency))\(change)", tint: tint, priority: 0)
    }

    var homeCard: AnyView? { AnyView(WatchlistHomeCard(module: self).onTapGesture { [ctx, id] in ctx.openPanel(id) }) }
    var panel: AnyView { AnyView(WatchlistPanel(module: self)) }
}

private struct ChangeLabel: View {
    let change: Double?
    var body: some View {
        if let change {
            Text(Money.change(change))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(change >= 0 ? Tokens.live : Tokens.error)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill((change >= 0 ? Tokens.live : Tokens.error).opacity(0.16)))
        } else {
            Text("—").font(.system(size: 11.5)).foregroundStyle(Tokens.faint)
        }
    }
}

private struct WatchlistHomeCard: View {
    let module: WatchlistAddOn
    var body: some View {
        let mood = module.mood
        NotchCard {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    CardLabel("Watchlist")
                    ForEach(module.items.prefix(3)) { item in
                        HStack {
                            Text(item.short).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if let q = module.quote(item) {
                                Text(Money.price(q.price, q.currency)).font(.system(size: 12).monospacedDigit())
                                ChangeLabel(change: q.change)
                            }
                        }
                    }
                    if module.items.isEmpty {
                        Text("Nothing on your list").font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 4) {
                    FinanceOrbitView(look: mood.orbit, size: 40)
                    Text(mood.direction == .up ? "Up" : mood.direction == .down ? "Down" : mood.direction == .flat ? "Calm" : "")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(mood.tint)
                }
                .frame(width: 48)
                .padding(.top, 6)
            }
        }
    }
}

private struct WatchlistPanel: View {
    @Bindable var module: WatchlistAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: module.symbol, title: "Watchlist", subtitle: statusLine, tint: FinanceUI.tint)
                if !module.editing {
                    FinanceIconButton(symbol: "arrow.clockwise", help: "Refresh", size: 30) { Task { await module.refresh() } }
                }
                GlassPillButton(title: module.editing ? "Done" : "Edit list", symbol: module.editing ? "checkmark" : "slider.horizontal.3") {
                    withAnimation(Tokens.spring) { module.editing.toggle() }
                }
            }
            if module.editing { editor } else { list }
        }
    }

    private var statusLine: String {
        if module.loading { return "Updating…" }
        let when = module.updated.map { "Updated \($0.formatted(.dateTime.hour().minute()))" } ?? "Not updated yet"
        if let error = module.error { return "\(error) Showing last prices." }
        return "\(when) · every 5 min"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchScroll {
                VStack(spacing: 2) {
                    if module.items.isEmpty {
                        VStack(spacing: 8) {
                            OrbitView(size: 56, mood: .happy, motion: .idle)
                            Text("Nothing on your list").font(.system(size: 13, weight: .semibold))
                            Text("Tap Edit list to pick coins and currency pairs.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    ForEach(module.items) { row($0) }
                }
                .padding(.vertical, 6)
            }
            HStack(spacing: 10) {
                if !module.items.isEmpty {
                    FinanceOrbitView(look: module.loading ? .thinking : module.mood.orbit, size: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !module.items.isEmpty {
                        Text(module.mood.line).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(module.mood.tint)
                    }
                    Text("Prices for information only. Crypto by CoinGecko, currency rates by the ECB.")
                        .font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
    }

    private func row(_ item: WatchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .coin ? "bitcoinsign.circle.fill" : "coloncurrencysign.circle")
                .font(.system(size: 16)).foregroundStyle(item.kind == .coin ? Tokens.attention : Tokens.zoom)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.short).font(.system(size: 13, weight: .semibold))
                Text(item.kind == .coin ? item.name : "Currency pair").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
            Spacer()
            if let q = module.quote(item) {
                Text(item.kind == .pair ? Money.plain(Money.decimal(q.price), decimals: 4) : Money.price(q.price, q.currency))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                ChangeLabel(change: q.change).frame(width: 74, alignment: .trailing)
            } else {
                Text(module.loading ? "Loading…" : "No price yet").font(.system(size: 12)).foregroundStyle(Tokens.faint)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                CardLabel("Crypto prices in")
                ForEach(Watchlist.currencies, id: \.self) { c in
                    FinanceChip(title: c, selected: module.currency == c) { module.currency = c }
                }
            }
            CardLabel("Crypto")
            FlowChips(items: Watchlist.coins.map { WatchItem.coin($0.id) }, module: module)
            CardLabel("Currency pairs")
            FlowChips(items: Watchlist.pairs.map { WatchItem.pair($0) }, module: module)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
    }

    private struct FlowChips: View {
        let items: [WatchItem]
        let module: WatchlistAddOn
        var body: some View {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    let on = module.items.contains(item)
                    Button { module.toggle(item) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                            Text(item.short).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .foregroundStyle(on ? .black : .white)
                        .background { if on { Capsule().fill(.white) } }
                        .glassSurface(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
