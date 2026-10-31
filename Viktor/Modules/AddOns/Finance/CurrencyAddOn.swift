import SwiftUI

/// Currency converter with ECB rates (Frankfurter). Keeps the last rates so it works offline.
@MainActor
@Observable
final class CurrencyAddOn: AddOnModule {
    let id = "addon.currency"
    let title = "Currency"
    let symbol = "dollarsign.arrow.circlepath"
    let addOn = AddOnInfo(category: .finance, tier: .free,
                          summary: "Convert between SEK, EUR, USD and 30 more currencies with the latest ECB rates.")

    struct Saved: Codable {
        var rates: FXRates?
        var from = "EUR"
        var to = "SEK"
        var amount = "100"
        var fetchedAt: Date?
    }

    private static let file = "addon-currency"
    private(set) var rates: FXRates?
    private(set) var fetchedAt: Date?
    private(set) var loading = false
    private(set) var error: String?
    var from: String { didSet { save() } }
    var to: String { didSet { save() } }
    var amountText: String { didSet { save() } }
    private var timer: Timer?
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        var saved = Storage.load(Saved.self, from: Self.file) ?? Saved()
        if ModuleRegistry.isPreview, saved.rates == nil { saved.rates = Self.sampleRates }
        rates = saved.rates; fetchedAt = saved.fetchedAt
        from = saved.from; to = saved.to; amountText = saved.amount
    }

    func start() {
        refreshIfStale()
        // ECB publishes once a day; checking every 3 hours is plenty.
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshIfStale() {
        guard !ModuleRegistry.isPreview else { return }
        if let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 3 * 3600, rates != nil { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            rates = try await Frankfurter.latest()
            fetchedAt = .now
            error = nil
            save()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't update rates."
        }
    }

    func swap() { (from, to) = (to, from) }

    var amount: Decimal? { Money.parse(amountText) }
    var result: Decimal? {
        guard let amount, let rates else { return nil }
        return rates.convert(amount, from: from, to: to)
    }
    var codes: [String] { FinanceUI.ordered(rates?.codes ?? FinanceUI.common) }

    private func save() {
        Storage.save(Saved(rates: rates, from: from, to: to, amount: amountText, fetchedAt: fetchedAt), to: Self.file)
    }

    /// Snapshot-only sample (roughly late-2026 levels), so the layout can be checked offline.
    static let sampleRates = FXRates(base: "EUR", date: "2026-10-27", rates: [
        "SEK": 11.21, "USD": 1.08, "GBP": 0.85, "NOK": 11.68, "DKK": 7.46, "CHF": 0.94, "JPY": 162.4,
        "PLN": 4.31, "CAD": 1.49, "AUD": 1.63, "CZK": 25.2, "HUF": 395.1, "ISK": 150.3, "NZD": 1.79,
    ])

    var homeCard: AnyView? { AnyView(CurrencyHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }
    var panel: AnyView { AnyView(CurrencyPanel(module: self)) }
}

private struct CurrencyHomeCard: View {
    let module: CurrencyAddOn
    let open: () -> Void
    var body: some View {
        NotchCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    CardLabel("Currency")
                    if let r = module.rates?.cross(module.from, module.to) {
                        Text("1 \(module.from) = \(Money.plain(Money.decimal(r), decimals: 4)) \(module.to)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text("Rates from \(Frankfurter.display(module.rates?.date ?? ""))").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                    } else {
                        Text("No rates yet").font(.system(size: 13, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                FinanceOrbitView(look: module.loading ? .thinking : .happy, size: 40)
            }
        }
        .onTapGesture(perform: open)
    }
}

private struct CurrencyPanel: View {
    @Bindable var module: CurrencyAddOn
    private enum Side { case from, to }
    @State private var picking: Side?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: "Currency converter", subtitle: statusLine, tint: FinanceUI.tint)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    FinanceField(placeholder: "Amount", text: $module.amountText, size: 20, height: 44)
                    currencyButton(.from)
                    FinanceIconButton(symbol: "arrow.left.arrow.right", help: "Swap", size: 34) {
                        withAnimation(Tokens.spring) { module.swap() }
                    }
                    currencyButton(.to)
                }
                if let side = picking {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(side == .from ? "Convert from" : "Convert to").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button("Done") { picking = nil }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        }
                        CurrencyGrid(codes: module.codes, selected: side == .from ? module.from : module.to) { code in
                            if side == .from { module.from = code } else { module.to = code }
                            picking = nil
                        }
                    }
                    .transition(.opacity)
                } else {
                    result
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(24)
        }
        .onAppear { module.refreshIfStale() }
    }

    private var statusLine: String {
        if module.loading { return "Updating rates…" }
        guard let r = module.rates else { return module.error ?? "Getting today's rates…" }
        return "Rates from \(Frankfurter.display(r.date)) · ECB" + (module.error != nil ? " · offline" : "")
    }

    private func currencyButton(_ side: Side) -> some View {
        let code = side == .from ? module.from : module.to
        return Button { withAnimation(Tokens.spring) { picking = picking == side ? nil : side } } label: {
            HStack(spacing: 5) {
                Text(code).font(.system(size: 14, weight: .semibold).monospaced())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.secondary)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .glassSurface(Capsule(), selected: picking == side)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var result: some View {
        if module.rates == nil {
            VStack(spacing: 8) {
                FinanceOrbitView(look: module.loading ? .thinking : FinanceOrbit(mood: .wide, motion: .idle), size: 56)
                Text(module.loading ? "Getting rates…" : "No rates yet").font(.system(size: 13, weight: .semibold))
                Text(module.error ?? "Rates load when you're online, then work offline too.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                GlassPillButton(title: "Try again", symbol: "arrow.clockwise") { Task { await module.refresh() } }
            }
            .frame(maxWidth: .infinity).padding(.top, 20)
        } else if let value = module.result, let amount = module.amount {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Money.format(amount, module.from)) =").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Money.format(Money.round(value), module.to))
                            .font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.5)
                        CopyButton(value: Money.plain(Money.round(value)))
                    }
                    if let r = module.rates?.cross(module.from, module.to), let back = module.rates?.cross(module.to, module.from) {
                        HStack(spacing: 14) {
                            Text("1 \(module.from) = \(Money.plain(Money.decimal(r), decimals: 4)) \(module.to)")
                            Text("1 \(module.to) = \(Money.plain(Money.decimal(back), decimals: 4)) \(module.from)")
                        }
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Tokens.secondary)
                    }
                }
                Spacer(minLength: 8)
                ExchangeOrbit(from: module.from, to: module.to, amount: module.amountText, loading: module.loading)
                    .padding(.trailing, 8)
            }
            quickAmounts
        } else {
            HStack(spacing: 10) {
                OrbitView(size: 34, mood: .normal, motion: .idle, gaze: CGVector(dx: -0.6, dy: -0.5))
                Text("Type an amount to convert.").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
            }
        }
    }

    /// One-tap amounts, with what each is worth.
    private var quickAmounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel("At a glance")
            HStack(spacing: 8) {
                ForEach([10, 100, 1000, 10000], id: \.self) { n in
                    let v = module.rates?.convert(Decimal(n), from: module.from, to: module.to) ?? 0
                    Button { module.amountText = "\(n)" } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Money.format(Decimal(n), module.from, decimals: 0)).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                            Text(Money.format(Money.round(v), module.to)).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// Orbit doing the exchange: the two currencies hang either side of it, and it stops to think
/// for a moment whenever the amount or the currencies change.
private struct ExchangeOrbit: View {
    let from: String
    let to: String
    let amount: String
    let loading: Bool

    var body: some View {
        ZStack {
            CalculatingOrbit(value: "\(amount)|\(from)|\(to)", size: 62, resting: loading ? .thinking : .happy)
                .offset(y: 12)
            tag(from).offset(x: -48, y: -26)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.faint)
                .offset(y: -26)
            tag(to).offset(x: 48, y: -26)
        }
        .frame(width: 150, height: 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit converting \(from) to \(to)")
    }

    private func tag(_ code: String) -> some View {
        Text(code).font(.system(size: 11, weight: .bold).monospaced())
            .padding(.horizontal, 8).frame(height: 22)
            .glassSurface(Capsule())
            .id(code)
            .transition(.scale.combined(with: .opacity))
    }
}
