import SwiftUI

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case food, transport, shopping, bills, fun, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .transport: "tram.fill"
        case .shopping: "bag.fill"
        case .bills: "doc.text.fill"
        case .fun: "party.popper.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .food: Color(red: 1, green: 0.62, blue: 0.3)
        case .transport: Tokens.zoom
        case .shopping: Color(red: 0.94, green: 0.5, blue: 0.75)
        case .bills: Color(red: 0.63, green: 0.59, blue: 0.99)
        case .fun: Tokens.live
        case .other: Color.white.opacity(0.6)
        }
    }
}

struct Expense: Codable, Identifiable, Equatable {
    var id = UUID()
    var amount: Decimal
    var category: ExpenseCategory
    var note: String = ""
    var date: Date = .now
}

struct BudgetData: Codable, Equatable {
    var monthly: Decimal = 8000
    var currency = "SEK"
    /// Every expense ever added; each month only counts its own, so history stays.
    var expenses: [Expense] = []

    func inMonth(of day: Date, _ cal: Calendar = .current) -> [Expense] {
        expenses.filter { cal.isDate($0.date, equalTo: day, toGranularity: .month) }.sorted { $0.date > $1.date }
    }
    func spent(in day: Date, _ cal: Calendar = .current) -> Decimal {
        inMonth(of: day, cal).reduce(0) { $0 + $1.amount }
    }
    func remaining(in day: Date, _ cal: Calendar = .current) -> Decimal { monthly - spent(in: day, cal) }
    func byCategory(in day: Date, _ cal: Calendar = .current) -> [(ExpenseCategory, Decimal)] {
        let list = inMonth(of: day, cal)
        return ExpenseCategory.allCases.map { c in (c, list.filter { $0.category == c }.reduce(0) { $0 + $1.amount }) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }
    /// How far through its month `day` is, 0 to 1 (the 15th of a 30-day month is 0.5).
    static func monthFraction(_ day: Date, _ cal: Calendar = .current) -> Double {
        let n = cal.range(of: .day, in: .month, for: day)?.count ?? 30
        return Double(cal.component(.day, from: day)) / Double(max(n, 1))
    }
    /// Totals for earlier months, newest first (month start, spent).
    func history(before day: Date, months: Int = 3, _ cal: Calendar = .current) -> [(Date, Decimal)] {
        (1...months).compactMap { back in
            guard let d = cal.date(byAdding: .month, value: -back, to: day) else { return nil }
            let total = spent(in: d, cal)
            return total > 0 ? (cal.dateInterval(of: .month, for: d)?.start ?? d, total) : nil
        }
    }
}

/// How the month is going, which sets Orbit's face: happy on track, wide-eyed when spending fast, grumpy over budget.
enum BudgetPace: Equatable {
    case fresh, onTrack, fast, nearlyOut, over

    /// `monthFraction` is how much of the month has gone (0…1). Spending a little ahead of it is fine.
    static func of(spent: Decimal, budget: Decimal, monthFraction: Double) -> BudgetPace {
        guard budget > 0 else { return .onTrack }
        if spent <= 0 { return .fresh }
        if spent > budget { return .over }
        let used = Money.double(spent) / Money.double(budget)
        if used >= 0.9 { return .nearlyOut }
        if used > monthFraction + 0.1 { return .fast }
        return .onTrack
    }

    var line: String {
        switch self {
        case .fresh: "Nothing spent yet"
        case .onTrack: "On track"
        case .fast: "Spending fast"
        case .nearlyOut: "Almost used up"
        case .over: "Over budget"
        }
    }

    var orbit: FinanceOrbit {
        switch self {
        case .fresh, .onTrack: .happy
        case .fast: FinanceOrbit(mood: .wide, motion: .idle)
        case .nearlyOut: FinanceOrbit(mood: .wide, motion: .nudge, tint: Tokens.attention)
        case .over: FinanceOrbit(mood: .grumpy, motion: .alert, tint: Tokens.error)
        }
    }

    var tint: Color {
        switch self {
        case .fresh, .onTrack: Tokens.live
        case .fast, .nearlyOut: Tokens.attention
        case .over: Tokens.error
        }
    }
}

/// A simple monthly budget: quick-add what you spend, see what's left.
@MainActor
@Observable
final class BudgetAddOn: AddOnModule {
    let id = "addon.budget"
    let title = "Budget"
    let symbol = "creditcard"
    let addOn = AddOnInfo(category: .finance, tier: .free,
                          summary: "Set a monthly budget, add what you spend in a tap and see what's left.")

    private static let file = "addon-budget"
    private(set) var data: BudgetData
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            let now = Date.now, cal = Calendar.current
            func ago(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now) ?? now }
            let lastMonth = cal.date(byAdding: .month, value: -1, to: now) ?? now
            data = BudgetData(monthly: 8000, currency: "SEK", expenses: [
                Expense(amount: 189, category: .food, note: "ICA", date: now),
                Expense(amount: 1040, category: .transport, note: "SL monthly pass", date: ago(0)),
                Expense(amount: 649, category: .shopping, note: "Shoes", date: ago(1)),
                Expense(amount: 420, category: .fun, note: "Cinema", date: ago(1)),
                Expense(amount: 1290, category: .bills, note: "Electricity", date: ago(2)),
                Expense(amount: 312, category: .food, note: "", date: ago(2)),
                Expense(amount: 6900, category: .other, note: "", date: lastMonth),
            ].filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) || $0.date == lastMonth })
        } else {
            data = Storage.load(BudgetData.self, from: Self.file) ?? BudgetData()
        }
    }

    func add(_ amount: Decimal, _ category: ExpenseCategory, note: String) {
        guard amount > 0 else { return }
        data.expenses.append(Expense(amount: Money.round(amount), category: category, note: note.trimmingCharacters(in: .whitespaces)))
        save()
    }

    func delete(_ e: Expense) { data.expenses.removeAll { $0.id == e.id }; save() }

    func setBudget(_ amount: Decimal) { guard amount > 0 else { return }; data.monthly = Money.round(amount); save() }
    func setCurrency(_ code: String) { data.currency = code; save() }

    var spent: Decimal { data.spent(in: .now) }
    var remaining: Decimal { data.remaining(in: .now) }
    var pace: BudgetPace { BudgetPace.of(spent: spent, budget: data.monthly, monthFraction: BudgetData.monthFraction(.now)) }
    var leftLine: String { "\(Money.format(remaining, data.currency, decimals: 0)) left of \(Money.format(data.monthly, data.currency, decimals: 0))" }

    private func save() { Storage.save(data, to: Self.file) }

    var homeCard: AnyView? { AnyView(BudgetHomeCard(module: self).onTapGesture { [ctx, id] in ctx.openPanel(id) }) }
    var panel: AnyView { AnyView(BudgetPanel(module: self)) }
}

private struct BudgetBar: View {
    let fraction: Double
    var tint: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}

private struct BudgetHomeCard: View {
    let module: BudgetAddOn
    var body: some View {
        let d = module.data
        let pace = module.pace
        NotchCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        CardLabel("Budget")
                        Text(pace.line).font(.system(size: 10.5, weight: .medium)).foregroundStyle(pace.tint)
                    }
                    Text(module.leftLine).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(module.remaining < 0 ? Tokens.error : .white)
                    BudgetBar(fraction: Money.double(module.spent) / max(Money.double(d.monthly), 1),
                              tint: module.remaining < 0 ? Tokens.error : FinanceUI.tint, height: 6)
                    Spacer(minLength: 0)
                }
                FinanceOrbitView(look: pace.orbit, size: 40)
            }
        }
    }
}

private struct BudgetPanel: View {
    let module: BudgetAddOn
    @State private var amount = ""
    @State private var note = ""
    @State private var category: ExpenseCategory = .food
    @State private var editingBudget = false
    @State private var budgetText = ""

    var body: some View {
        let d = module.data
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AddOnHeader(symbol: module.symbol, title: "Budget",
                            subtitle: Date.now.formatted(.dateTime.month(.wide).year()) + " · new month starts fresh",
                            tint: FinanceUI.tint)
                GlassPillButton(title: editingBudget ? "Cancel" : "Set budget", symbol: editingBudget ? nil : "pencil") {
                    budgetText = Money.plain(d.monthly, decimals: 0)
                    withAnimation(Tokens.spring) { editingBudget.toggle() }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    if editingBudget { budgetEditor } else { quickAdd }
                }
                .frame(width: 330)
                expenseList
            }
        }
    }

    private var summary: some View {
        let d = module.data
        let over = module.remaining < 0
        let pace = module.pace
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Money.format(over ? -module.remaining : module.remaining, d.currency, decimals: 0))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(over ? Tokens.error : .white)
                        Text(over ? "over budget" : "left").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
                    }
                    HStack(spacing: 5) {
                        Text(pace.line).foregroundStyle(pace.tint)
                        Text("·").foregroundStyle(Tokens.faint)
                        Text("of \(Money.format(d.monthly, d.currency, decimals: 0))").monospacedDigit().foregroundStyle(Tokens.secondary)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                Spacer(minLength: 4)
                FinanceOrbitView(look: pace.orbit, size: 46)
            }
            BudgetBar(fraction: Money.double(module.spent) / max(Money.double(d.monthly), 1), tint: over ? Tokens.error : FinanceUI.tint)
            let cats = d.byCategory(in: .now)
            if cats.isEmpty {
                Text("Nothing spent yet this month.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(cats, id: \.0) { cat, total in
                        HStack(spacing: 8) {
                            Image(systemName: cat.symbol).font(.system(size: 10)).foregroundStyle(cat.tint).frame(width: 14)
                            Text(cat.title).font(.system(size: 11.5)).frame(width: 70, alignment: .leading)
                            BudgetBar(fraction: Money.double(total) / max(Money.double(module.spent), 1), tint: cat.tint, height: 6)
                            Text(Money.format(total, d.currency, decimals: 0)).font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Tokens.secondary).frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(22)
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel("Add expense")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(ExpenseCategory.allCases) { c in
                    FinanceChip(title: c.title, symbol: c.symbol, selected: category == c, tint: c.tint, stretch: true) { category = c }
                }
            }
            HStack(spacing: 6) {
                FinanceField(placeholder: "Amount", text: $amount, onSubmit: add).frame(width: 100)
                FinanceField(placeholder: "Note (optional)", text: $note, onSubmit: add)
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white)).foregroundStyle(.black)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Add expense")
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(22)
    }

    private var budgetEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardLabel("Monthly budget")
            HStack(spacing: 6) {
                FinanceField(placeholder: "Amount", text: $budgetText, onSubmit: saveBudget)
                PillButton(title: "Save", action: saveBudget)
            }
            CardLabel("Currency")
            HStack(spacing: 6) {
                ForEach(["SEK", "EUR", "USD", "NOK", "DKK"], id: \.self) { c in
                    FinanceChip(title: c, selected: module.data.currency == c) { module.setCurrency(c) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(22)
    }

    private var expenseList: some View {
        let d = module.data
        let list = d.inMonth(of: .now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                CardLabel("This month")
                Spacer()
                Text("\(list.count) \(list.count == 1 ? "expense" : "expenses") · \(Money.format(module.spent, d.currency, decimals: 0))")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Tokens.faint)
            }
            .padding(.horizontal, 8).padding(.top, 10)
            NotchScroll {
                VStack(spacing: 0) {
                    if list.isEmpty {
                        VStack(spacing: 8) {
                            OrbitView(size: 52, mood: .happy, motion: .idle)
                            Text("Nothing spent yet").font(.system(size: 13, weight: .semibold))
                            Text("Your expenses show up here.").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    ForEach(list) { ExpenseRow(expense: $0, currency: d.currency) { e in module.delete(e) } }
                }
            }
            let history = d.history(before: .now)
            if !history.isEmpty {
                HStack(spacing: 10) {
                    ForEach(history, id: \.0) { month, total in
                        Text("\(month.formatted(.dateTime.month(.wide))) \(Money.format(total, d.currency, decimals: 0))")
                    }
                }
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Tokens.faint)
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(22)
    }

    private func add() {
        guard let value = Money.parse(amount), value > 0 else { return }
        module.add(value, category, note: note)
        amount = ""; note = ""
    }

    private func saveBudget() {
        guard let value = Money.parse(budgetText), value > 0 else { return }
        module.setBudget(value)
        withAnimation(Tokens.spring) { editingBudget = false }
    }
}

private struct ExpenseRow: View {
    let expense: Expense
    let currency: String
    let delete: (Expense) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expense.category.symbol).font(.system(size: 11)).foregroundStyle(expense.category.tint)
                .frame(width: 26, height: 26).glassSurface(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(expense.note.isEmpty ? expense.category.title : expense.note).font(.system(size: 12.5)).lineLimit(1)
                Text(dayLabel).font(.system(size: 10.5)).foregroundStyle(Tokens.secondary)
            }
            Spacer(minLength: 4)
            Text(Money.smart(expense.amount, currency)).font(.system(size: 12.5, weight: .medium).monospacedDigit())
            Button { delete(expense) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.faint)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete").opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Color.white.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
    }

    private var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(expense.date) { return "Today" }
        if cal.isDateInYesterday(expense.date) { return "Yesterday" }
        return expense.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
