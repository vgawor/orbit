import SwiftUI

enum BillingCycle: String, Codable, CaseIterable, Identifiable {
    case weekly, monthly, yearly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var short: String { switch self { case .weekly: "/wk"; case .monthly: "/mo"; case .yearly: "/yr" } }
    var step: DateComponents {
        switch self {
        case .weekly: DateComponents(day: 7)
        case .monthly: DateComponents(month: 1)
        case .yearly: DateComponents(year: 1)
        }
    }
}

struct Subscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var price: Decimal
    var currency: String = "SEK"
    var cycle: BillingCycle = .monthly
    var nextRenewal: Date
    /// The renewal date we last warned about, so each renewal alerts once.
    var alertedFor: Date?

    /// What it costs per month on average (yearly ÷ 12, weekly × 52 ÷ 12).
    var monthly: Decimal {
        switch cycle {
        case .monthly: price
        case .yearly: price / 12
        case .weekly: price * 52 / 12
        }
    }
    var yearly: Decimal {
        switch cycle {
        case .monthly: price * 12
        case .yearly: price
        case .weekly: price * 52
        }
    }
}

enum Subscriptions {
    /// Moves `date` forward by whole cycles until it's today or later. The day of month is kept from the
    /// original (31 Jan → 28 Feb → 31 Mar) by always counting from the first date.
    static func advance(_ date: Date, cycle: BillingCycle, now: Date = .now, _ cal: Calendar = .current) -> Date {
        let today = cal.startOfDay(for: now)
        guard date < today else { return date }
        var n = 1, next = date
        while next < today, n < 5000 {
            var step = DateComponents()
            switch cycle {
            case .weekly: step.day = 7 * n
            case .monthly: step.month = n
            case .yearly: step.year = n
            }
            next = cal.date(byAdding: step, to: date) ?? today
            n += 1
        }
        return next
    }

    /// Whole days from today to the renewal (0 = today).
    static func daysUntil(_ date: Date, now: Date = .now, _ cal: Calendar = .current) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Monthly and yearly totals per currency, biggest first.
    static func totals(_ subs: [Subscription]) -> [(currency: String, monthly: Decimal, yearly: Decimal)] {
        Dictionary(grouping: subs, by: \.currency)
            .map { (currency: $0.key, monthly: Money.round($0.value.reduce(0) { $0 + $1.monthly }),
                    yearly: Money.round($0.value.reduce(0) { $0 + $1.yearly })) }
            .sorted { $0.monthly > $1.monthly }
    }

    /// Subscriptions that renew within `days` days and haven't been warned about for that renewal.
    static func due(_ subs: [Subscription], within days: Int = 2, now: Date = .now, _ cal: Calendar = .current) -> [Subscription] {
        subs.filter { s in
            let d = daysUntil(s.nextRenewal, now: now, cal)
            return (0...days).contains(d) && !(s.alertedFor.map { cal.isDate($0, inSameDayAs: s.nextRenewal) } ?? false)
        }
    }

    /// Orbit for the next renewal: hops to nudge you when one is two days away or less, looks over
    /// when one is this week, and is relaxed otherwise. nil = no subscriptions.
    static func orbit(daysUntil days: Int?) -> FinanceOrbit {
        guard let days else { return .happy }
        switch days {
        case ...2: return FinanceOrbit(mood: .wide, motion: .nudge, tint: Tokens.attention)
        case 3..<7: return FinanceOrbit(mood: .normal, motion: .idle)
        default: return .happy
        }
    }
}

/// Keeps track of subscriptions: totals, next renewal, a heads-up two days before.
@MainActor
@Observable
final class SubscriptionsAddOn: AddOnModule {
    let id = "addon.subscriptions"
    let title = "Subscriptions"
    let symbol = "repeat.circle"
    let addOn = AddOnInfo(category: .finance, tier: .free,
                          summary: "All your subscriptions in one list, with totals and a heads-up two days before each renewal.")

    private static let file = "addon-subscriptions"
    private(set) var subs: [Subscription]
    var composing = false
    private var timer: Timer?
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            let cal = Calendar.current
            func inDays(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: .now)) ?? .now }
            subs = [
                Subscription(name: "Spotify", price: 129, cycle: .monthly, nextRenewal: inDays(2)),
                Subscription(name: "Netflix", price: 149, cycle: .monthly, nextRenewal: inDays(9)),
                Subscription(name: "iCloud+", price: 39, cycle: .monthly, nextRenewal: inDays(14)),
                Subscription(name: "ChatGPT", price: 20, currency: "USD", cycle: .monthly, nextRenewal: inDays(17)),
                Subscription(name: "Figma", price: 144, currency: "EUR", cycle: .yearly, nextRenewal: inDays(120)),
            ]
        } else {
            subs = Storage.load([Subscription].self, from: Self.file) ?? []
        }
    }

    func start() {
        check()
        // Hourly is enough to catch the day changing; each renewal alerts once.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Moves past renewals forward, then warns about the ones coming up.
    func check(now: Date = .now) {
        var changed = false
        for i in subs.indices {
            let next = Subscriptions.advance(subs[i].nextRenewal, cycle: subs[i].cycle, now: now)
            if next != subs[i].nextRenewal { subs[i].nextRenewal = next; changed = true }
        }
        for s in Subscriptions.due(subs, now: now) {
            let days = Subscriptions.daysUntil(s.nextRenewal, now: now)
            let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
            ctx.alerts.post(NotchAlert(symbol: symbol, tint: FinanceUI.tint,
                                       title: "\(s.name) renews \(when)",
                                       subtitle: "\(Money.format(s.price, s.currency)) · \(s.cycle.title.lowercased())",
                                       actions: [.init(title: "OK", isPrimary: true)], duration: 6, sound: "Glass"))
            if let i = subs.firstIndex(where: { $0.id == s.id }) { subs[i].alertedFor = s.nextRenewal; changed = true }
        }
        if changed { save() }
    }

    func add(_ s: Subscription) {
        var s = s
        s.nextRenewal = Subscriptions.advance(s.nextRenewal, cycle: s.cycle)
        subs.append(s)
        save()
        check()
    }

    func delete(_ s: Subscription) { subs.removeAll { $0.id == s.id }; save() }

    var sorted: [Subscription] { subs.sorted { $0.nextRenewal < $1.nextRenewal } }
    var orbit: FinanceOrbit { Subscriptions.orbit(daysUntil: sorted.first.map { Subscriptions.daysUntil($0.nextRenewal) }) }

    private func save() { if !ModuleRegistry.isPreview { Storage.save(subs, to: Self.file) } }

    var attention: Attention? {
        guard let s = sorted.first, Subscriptions.daysUntil(s.nextRenewal) == 0 else { return nil }
        return Attention(id: "sub-\(s.id)-\(s.nextRenewal.timeIntervalSince1970)", symbol: symbol, tint: FinanceUI.tint,
                         label: s.name, priority: 0, headline: "\(s.name) renews today")
    }

    var homeCard: AnyView? { AnyView(SubscriptionsHomeCard(module: self).onTapGesture { [ctx, id] in ctx.openPanel(id) }) }
    var panel: AnyView { AnyView(SubscriptionsPanel(module: self)) }
}

private func renewalLabel(_ date: Date) -> String {
    let d = Subscriptions.daysUntil(date)
    switch d {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case 2..<7: return "In \(d) days"
    default: return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct SubscriptionsHomeCard: View {
    let module: SubscriptionsAddOn
    var body: some View {
        NotchCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    CardLabel("Subscriptions")
                    if let s = module.sorted.first {
                        HStack(spacing: 0) {
                            Text("\(s.name) · ")
                            Text(renewalLabel(s.nextRenewal))
                                .foregroundStyle(Subscriptions.daysUntil(s.nextRenewal) <= 2 ? Tokens.attention : .white)
                        }
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let t = Subscriptions.totals(module.subs).first {
                            Text("\(Money.format(t.monthly, t.currency, decimals: 0)) a month").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                    } else {
                        Text("None yet").font(.system(size: 13, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                FinanceOrbitView(look: module.orbit, size: 40)
            }
        }
    }
}

private struct SubscriptionsPanel: View {
    @Bindable var module: SubscriptionsAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AddOnHeader(symbol: module.symbol, title: "Subscriptions",
                            subtitle: module.subs.isEmpty ? "Add what you pay for regularly" : "\(module.subs.count) active · alerts 2 days before renewal",
                            tint: FinanceUI.tint)
                if !module.composing {
                    PillButton(title: "Add") { withAnimation(Tokens.spring) { module.composing = true } }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                list
                if module.composing {
                    SubscriptionForm(module: module)
                        .frame(width: 290)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    totals.frame(width: 200)
                }
            }
        }
    }

    private var list: some View {
        NotchScroll {
            VStack(spacing: 0) {
                if module.subs.isEmpty {
                    VStack(spacing: 8) {
                        OrbitView(size: 56, mood: .happy, motion: .idle)
                        Text("No subscriptions yet").font(.system(size: 13, weight: .semibold))
                        Text("Add Spotify, Netflix, your gym… and see what they cost together.")
                            .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 20)
                }
                ForEach(module.sorted) { SubscriptionRow(sub: $0) { s in module.delete(s) } }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }

    private var totals: some View {
        let all = Subscriptions.totals(module.subs)
        return VStack(alignment: .leading, spacing: 12) {
            CardLabel("Per month")
            if all.isEmpty { Text("—").foregroundStyle(Tokens.faint) }
            ForEach(all, id: \.currency) { t in
                Text(Money.smart(t.monthly, t.currency)).font(.system(size: all.count > 1 ? 17 : 24, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            CardLabel("Per year")
            ForEach(all, id: \.currency) { t in
                Text(Money.smart(t.yearly, t.currency)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.secondary)
            }
            Spacer(minLength: 0)
            if let next = module.sorted.first {
                VStack(alignment: .leading, spacing: 6) {
                    FinanceOrbitView(look: module.orbit, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        CardLabel("Next renewal")
                        Text(next.name).font(.system(size: 13, weight: .semibold))
                        Text("\(renewalLabel(next.nextRenewal)) · \(Money.smart(next.price, next.currency))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Subscriptions.daysUntil(next.nextRenewal) <= 2 ? Tokens.attention : Tokens.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }
}

private struct SubscriptionRow: View {
    let sub: Subscription
    let delete: (Subscription) -> Void
    @State private var hovering = false

    var body: some View {
        let days = Subscriptions.daysUntil(sub.nextRenewal)
        HStack(spacing: 10) {
            Text(String(sub.name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30).glassSurface(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(sub.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(renewalLabel(sub.nextRenewal)).font(.system(size: 11))
                    .foregroundStyle(days <= 2 ? Tokens.attention : Tokens.secondary)
            }
            Spacer(minLength: 4)
            Text(Money.smart(sub.price, sub.currency) + sub.cycle.short)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            Button { delete(sub) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.faint)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove").opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Color.white.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
    }
}

private struct SubscriptionForm: View {
    let module: SubscriptionsAddOn
    @State private var name = ""
    @State private var price = ""
    @State private var currency = "SEK"
    @State private var cycle: BillingCycle = .monthly
    @State private var next = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CardLabel("New subscription")
            FinanceField(placeholder: "Name, like Spotify", text: $name)
            FinanceField(placeholder: "Price", text: $price)
            HStack(spacing: 4) {
                ForEach(["SEK", "EUR", "USD", "NOK"], id: \.self) { c in FinanceChip(title: c, selected: currency == c) { currency = c } }
            }
            HStack(spacing: 4) {
                ForEach(BillingCycle.allCases) { c in FinanceChip(title: c.title, selected: cycle == c) { cycle = c } }
            }
            HStack {
                Text("Next renewal").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                Spacer()
                DatePicker("", selection: $next, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                    .controlSize(.small).fixedSize()
            }
            Spacer(minLength: 0)
            HStack {
                GlassPillButton(title: "Cancel") { withAnimation(Tokens.spring) { module.composing = false } }
                Spacer()
                PillButton(title: "Add subscription", action: save)
                    .opacity(canSave ? 1 : 0.5).disabled(!canSave)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), selected: true)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(price) ?? 0) > 0 }

    private func save() {
        guard canSave, let p = Money.parse(price) else { return }
        module.add(Subscription(name: name.trimmingCharacters(in: .whitespaces), price: Money.round(p), currency: currency,
                                cycle: cycle, nextRenewal: Calendar.current.startOfDay(for: next)))
        withAnimation(Tokens.spring) { module.composing = false }
    }
}
