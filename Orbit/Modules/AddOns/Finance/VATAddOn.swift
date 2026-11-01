import SwiftUI

enum VAT {
    struct Breakdown: Equatable { let net: Decimal; let vat: Decimal; let gross: Decimal }

    /// Net, VAT and gross for an amount. `rate` is a percentage (25 = 25 %).
    /// With `includesVAT`, the amount is the gross price; otherwise it's the net price.
    static func breakdown(_ amount: Decimal, rate: Decimal, includesVAT: Bool) -> Breakdown {
        let r = rate / 100
        if includesVAT {
            let net = Money.round(amount / (1 + r))
            let gross = Money.round(amount)
            return Breakdown(net: net, vat: gross - net, gross: gross)
        }
        let net = Money.round(amount)
        let vat = Money.round(amount * r)
        return Breakdown(net: net, vat: vat, gross: net + vat)
    }

    /// What to put aside for tax at `percent`, and what's left.
    static func setAside(_ amount: Decimal, percent: Decimal) -> (aside: Decimal, left: Decimal) {
        let aside = Money.round(amount * percent / 100)
        return (aside, Money.round(amount) - aside)
    }

    /// Swedish VAT rates.
    static let swedishRates: [Decimal] = [25, 12, 6, 0]
}

/// VAT & tax calculator (Swedish rates, or your own).
@MainActor
@Observable
final class VATAddOn: AddOnModule {
    let id = "addon.vat"
    let title = "VAT"
    let symbol = "percent"
    let addOn = AddOnInfo(category: .finance, tier: .free,
                          summary: "Add or remove Swedish VAT (25, 12, 6 %) and see how much to set aside for tax.")

    struct Saved: Codable {
        var amount = "1000"
        var rate: Decimal = 25
        var custom = ""
        var useCustom = false
        var includesVAT = false
        var taxPercent = "30"
    }

    private static let file = "addon-vat"
    var s: Saved { didSet { Storage.save(s, to: Self.file) } }

    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        s = ModuleRegistry.isPreview ? Saved() : (Storage.load(Saved.self, from: Self.file) ?? Saved())
    }

    var rate: Decimal? { s.useCustom ? Money.parse(s.custom) : s.rate }
    var breakdown: VAT.Breakdown? {
        guard let a = Money.parse(s.amount), let rate else { return nil }
        return VAT.breakdown(a, rate: rate, includesVAT: s.includesVAT)
    }
    /// "25 %", "12,5 %", or "–" when the custom rate can't be read.
    var rateLabel: String { rate.map { "\(Money.plain($0, decimals: $0 == Money.round($0, 0) ? 0 : 2)) %" } ?? "–" }
    /// What's left after setting aside tax from the net amount.
    var taxSplit: (aside: Decimal, left: Decimal)? {
        guard let b = breakdown else { return nil }
        return VAT.setAside(b.net, percent: Money.parse(s.taxPercent) ?? 0)
    }
    /// Changes whenever any input does, so Orbit can stop and think.
    var inputKey: String { "\(s.amount)|\(s.rate)|\(s.custom)|\(s.useCustom)|\(s.includesVAT)|\(s.taxPercent)" }

    var homeCard: AnyView? { AnyView(VATHomeCard(module: self).onTapGesture { [ctx, id] in ctx.openPanel(id) }) }
    var panel: AnyView { AnyView(VATPanel(module: self)) }
}

/// The last sum you did, at a glance: net, VAT and total, and what to put aside.
private struct VATHomeCard: View {
    let module: VATAddOn
    var body: some View {
        NotchCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        CardLabel("VAT & tax")
                        Text(module.rateLabel + (module.s.includesVAT ? " incl." : " excl."))
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.secondary)
                    }
                    if let b = module.breakdown {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(Money.format(b.net, "SEK", decimals: 0)).foregroundStyle(Tokens.secondary)
                            Text("+ \(Money.format(b.vat, "SEK", decimals: 0))").foregroundStyle(Tokens.secondary)
                            Text("=").foregroundStyle(Tokens.faint)
                            Text(Money.format(b.gross, "SEK", decimals: 0)).fontWeight(.semibold)
                        }
                        .font(.system(size: 13).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        if let split = module.taxSplit {
                            Text("Set aside \(Money.format(split.aside, "SEK", decimals: 0)) for tax · \(Money.format(split.left, "SEK", decimals: 0)) left")
                                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Tokens.secondary).lineLimit(1)
                        }
                    } else {
                        Text("Type an amount to work out VAT").font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                CalculatingOrbit(value: module.inputKey, size: 40,
                                 resting: module.breakdown == nil ? FinanceOrbit(mood: .normal, motion: .idle) : .happy)
            }
        }
    }
}

private struct VATPanel: View {
    @Bindable var module: VATAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AddOnHeader(symbol: module.symbol, title: "VAT & tax", subtitle: "Swedish rates · amounts in kr", tint: FinanceUI.tint)
            HStack(alignment: .top, spacing: 10) {
                inputs.frame(width: 300)
                VStack(spacing: 10) {
                    results
                    tax
                }
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardLabel("Amount")
            FinanceField(placeholder: "Amount", text: $module.s.amount, size: 20, height: 44)
            HStack(spacing: 2) {
                segment("Excl. VAT", !module.s.includesVAT) { module.s.includesVAT = false }
                segment("Incl. VAT", module.s.includesVAT) { module.s.includesVAT = true }
            }
            .padding(3).glassSurface(Capsule())
            CardLabel("VAT rate").padding(.top, 4)
            HStack(spacing: 5) {
                ForEach(VAT.swedishRates, id: \.self) { r in
                    FinanceChip(title: "\(Money.plain(r, decimals: 0)) %", selected: !module.s.useCustom && module.s.rate == r) {
                        module.s.rate = r; module.s.useCustom = false
                    }
                }
                FinanceChip(title: "Custom", selected: module.s.useCustom) { module.s.useCustom = true }
            }
            if module.s.useCustom {
                HStack(spacing: 6) {
                    FinanceField(placeholder: "Rate, e.g. 19", text: $module.s.custom).frame(width: 120)
                    Text("%").foregroundStyle(Tokens.secondary)
                }
            }
            Text(rateHint).font(.system(size: 11)).foregroundStyle(Tokens.faint).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 12) {
                CalculatingOrbit(value: module.inputKey, size: 54,
                                 resting: module.breakdown == nil ? FinanceOrbit(mood: .wide, motion: .idle) : .happy)
                Text(orbitLine).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }

    /// Orbit's take on the sum, in a few words.
    private var orbitLine: String {
        guard let b = module.breakdown else {
            return Money.parse(module.s.amount) == nil ? "Type an amount and I'll do the maths." : "Pick a rate I can read."
        }
        if b.vat == 0 { return "No VAT on this one." }
        return module.s.includesVAT
            ? "\(Money.format(b.vat, "SEK")) of that is VAT."
            : "Add \(Money.format(b.vat, "SEK")) VAT on top."
    }

    private var rateHint: String {
        switch module.rate {
        case 25: "25 % — most goods and services."
        case 12: "12 % — food, restaurants, hotels."
        case 6: "6 % — books, newspapers, passenger transport, culture."
        case 0: "0 % — exempt, such as healthcare and some exports."
        default: "Your own rate."
        }
    }

    private func segment(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 26)
                .foregroundStyle(on ? .white : Tokens.secondary)
                .background { if on { Capsule().fill(Color.white.opacity(0.17)) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var results: some View {
        let b = module.breakdown
        return VStack(spacing: 6) {
            line("Net (excl. VAT)", b?.net, bold: false)
            line("VAT \(module.rate.map { Money.plain($0, decimals: $0 == $0.rounded0 ? 0 : 2) } ?? "–") %", b?.vat, bold: false)
            Divider().overlay(Tokens.stroke)
            line("Total (incl. VAT)", b?.gross, bold: true)
        }
        .padding(14)
        .glassCard(22)
    }

    private func line(_ label: String, _ value: Decimal?, bold: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(bold ? .white : Tokens.secondary)
            Spacer()
            Text(value.map { Money.format($0, "SEK") } ?? "—")
                .font(.system(size: bold ? 17 : 14, weight: bold ? .semibold : .medium).monospacedDigit())
            if let value { CopyButton(value: Money.plain(value)) }
        }
    }

    private var tax: some View {
        let pct = Money.parse(module.s.taxPercent) ?? 0
        let base = module.breakdown?.net ?? 0
        let split = VAT.setAside(base, percent: pct)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CardLabel("Set aside for tax")
                Spacer()
                FinanceField(placeholder: "30", text: $module.s.taxPercent, size: 12, height: 26).frame(width: 56)
                Text("% of net").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }
            HStack(spacing: 8) {
                Text("Set aside").font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                Spacer()
                Text(Money.format(split.aside, "SEK")).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Tokens.attention)
                CopyButton(value: Money.plain(split.aside))
            }
            HStack(spacing: 8) {
                Text("Left for you").font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                Spacer()
                Text(Money.format(split.left, "SEK")).font(.system(size: 17, weight: .semibold).monospacedDigit())
                CopyButton(value: Money.plain(split.left))
            }
            Spacer(minLength: 0)
            Text("A rough guide, not tax advice. Your real tax depends on your income and municipality.")
                .font(.system(size: 10.5)).foregroundStyle(Tokens.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }
}

private extension Decimal {
    var rounded0: Decimal { Money.round(self, 0) }
}
