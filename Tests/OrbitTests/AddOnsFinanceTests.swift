import Foundation
import Testing
@testable import Orbit

@Suite("Finance add-ons")
struct AddOnsFinanceTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
    }

    // MARK: Parsing amounts

    @Test func parsesTypedAmounts() {
        #expect(Money.parse("1234") == 1234)
        #expect(Money.parse("1 234,50") == Decimal(string: "1234.5"))
        #expect(Money.parse("1234.50") == Decimal(string: "1234.5"))
        #expect(Money.parse("1,234.50") == Decimal(string: "1234.5"))
        #expect(Money.parse("1.234,50") == Decimal(string: "1234.5"))
        #expect(Money.parse("250 kr") == 250)
        #expect(Money.parse("") == nil)
        #expect(Money.parse("abc") == nil)
    }

    @Test func roundsMoney() {
        #expect(Money.round(Decimal(string: "10.005")!) == Decimal(string: "10.01"))
        #expect(Money.round(Decimal(string: "10.004")!) == Decimal(string: "10"))
    }

    // MARK: Currency

    let latestJSON = #"{"amount":1.0,"base":"EUR","date":"2026-10-27","rates":{"SEK":11.2,"USD":1.12,"NOK":11.6}}"#

    @Test func parsesFrankfurterLatest() throws {
        let r = try #require(Frankfurter.parseLatest(Data(latestJSON.utf8)))
        #expect(r.base == "EUR")
        #expect(r.date == "2026-10-27")
        #expect(r.rates["SEK"] == 11.2)
        #expect(r.codes.contains("EUR"))
        #expect(Frankfurter.parseLatest(Data("oops".utf8)) == nil)
    }

    @Test func convertsThroughBase() throws {
        let r = try #require(Frankfurter.parseLatest(Data(latestJSON.utf8)))
        #expect(Money.round(r.convert(100, from: "EUR", to: "SEK")!) == 1120)
        #expect(Money.round(r.convert(1120, from: "SEK", to: "EUR")!) == 100)
        // USD → SEK goes via EUR: 112 USD = 100 EUR = 1120 SEK.
        #expect(Money.round(r.convert(112, from: "USD", to: "SEK")!) == 1120)
        #expect(r.convert(1, from: "XXX", to: "SEK") == nil)
    }

    @Test func parsesFrankfurterSeriesAndPairChange() {
        let json = #"{"amount":1.0,"base":"EUR","start_date":"2026-10-23","end_date":"2026-10-27","rates":{"2026-10-27":{"SEK":11.22,"USD":1.10},"2026-10-23":{"SEK":11.0,"USD":1.10}}}"#
        let days = Frankfurter.parseSeries(Data(json.utf8))
        #expect(days.map(\.date) == ["2026-10-23", "2026-10-27"])
        let q = Watchlist.pairQuote(("EUR", "SEK"), days: days)
        #expect(q?.price == 11.22)
        #expect(abs((q?.change ?? 0) - 2.0) < 0.0001)
        #expect(q?.currency == "SEK")
        let usdsek = Watchlist.pairQuote(("USD", "SEK"), days: days)
        #expect(abs((usdsek?.price ?? 0) - 10.2) < 0.0001)
    }

    // MARK: Watchlist

    @Test func parsesCoinGecko() {
        let json = #"{"bitcoin":{"sek":1084230.5,"sek_24h_change":2.31},"ethereum":{"sek":41870}}"#
        let q = Watchlist.parseCoinGecko(Data(json.utf8), currency: "SEK")
        #expect(q["bitcoin"]?.price == 1084230.5)
        #expect(q["bitcoin"]?.change == 2.31)
        #expect(q["ethereum"]?.change == nil)
        #expect(q["ethereum"]?.currency == "SEK")
        #expect(Watchlist.parseCoinGecko(Data(#"{"status":{"error_code":429}}"#.utf8), currency: "SEK").isEmpty)
    }

    @Test func watchItemsParsePairs() {
        #expect(WatchItem.pair("EUR/SEK").pairCodes?.0 == "EUR")
        #expect(WatchItem.pair("EUR/SEK").pairCodes?.1 == "SEK")
        #expect(WatchItem.coin("bitcoin").pairCodes == nil)
        #expect(WatchItem.coin("bitcoin").short == "BTC")
    }

    // MARK: VAT

    @Test func addsVAT() {
        let b = VAT.breakdown(1000, rate: 25, includesVAT: false)
        #expect(b == .init(net: 1000, vat: 250, gross: 1250))
    }

    @Test func removesVAT() {
        let b = VAT.breakdown(1250, rate: 25, includesVAT: true)
        #expect(b == .init(net: 1000, vat: 250, gross: 1250))
        let food = VAT.breakdown(100, rate: 12, includesVAT: true)
        #expect(food.net == Decimal(string: "89.29"))
        #expect(food.vat == Decimal(string: "10.71"))
        #expect(VAT.breakdown(500, rate: 0, includesVAT: true).vat == 0)
    }

    @Test func setsAsideForTax() {
        let s = VAT.setAside(1000, percent: 30)
        #expect(s.aside == 300)
        #expect(s.left == 700)
    }

    // MARK: Budget

    @Test func budgetCountsOnlyThisMonth() {
        let now = day(2026, 10, 15)
        let data = BudgetData(monthly: 5000, currency: "SEK", expenses: [
            Expense(amount: 100, category: .food, date: day(2026, 10, 2)),
            Expense(amount: 250, category: .food, date: day(2026, 10, 14)),
            Expense(amount: 400, category: .fun, date: day(2026, 10, 15)),
            Expense(amount: 999, category: .bills, date: day(2026, 9, 30)),
        ])
        #expect(data.spent(in: now, cal) == 750)
        #expect(data.remaining(in: now, cal) == 4250)
        #expect(data.inMonth(of: now, cal).count == 3)
        let cats = data.byCategory(in: now, cal)
        #expect(cats.first?.0 == .fun)
        #expect(cats.first?.1 == 400)
        #expect(cats.count == 2)
        // A new month starts fresh, but last month is kept.
        #expect(data.spent(in: day(2026, 11, 1), cal) == 0)
        #expect(data.history(before: day(2026, 11, 1), cal).first?.1 == 750)
    }

    // MARK: Subscriptions

    @Test func advancesRenewalPastToday() {
        let now = day(2026, 10, 28)
        #expect(cal.isDate(Subscriptions.advance(day(2026, 10, 10), cycle: .monthly, now: now, cal), inSameDayAs: day(2026, 11, 10)))
        #expect(cal.isDate(Subscriptions.advance(day(2026, 10, 20), cycle: .weekly, now: now, cal), inSameDayAs: day(2026, 11, 3)))
        #expect(cal.isDate(Subscriptions.advance(day(2025, 3, 1), cycle: .yearly, now: now, cal), inSameDayAs: day(2027, 3, 1)))
        // Today and the future stay put.
        #expect(Subscriptions.advance(day(2026, 10, 28), cycle: .monthly, now: now, cal) == day(2026, 10, 28))
        #expect(Subscriptions.advance(day(2026, 12, 1), cycle: .monthly, now: now, cal) == day(2026, 12, 1))
    }

    @Test func keepsEndOfMonthDay() {
        // 31 Jan monthly, checked in April → 30 Apr (counted from 31 Jan, not from 28 Feb).
        let next = Subscriptions.advance(day(2026, 1, 31), cycle: .monthly, now: day(2026, 4, 2), cal)
        #expect(cal.isDate(next, inSameDayAs: day(2026, 4, 30)))
    }

    @Test func totalsPerCurrency() {
        let subs = [
            Subscription(name: "A", price: 100, cycle: .monthly, nextRenewal: .now),
            Subscription(name: "B", price: 1200, cycle: .yearly, nextRenewal: .now),
            Subscription(name: "C", price: 12, currency: "USD", cycle: .weekly, nextRenewal: .now),
        ]
        let t = Subscriptions.totals(subs)
        let sek = t.first { $0.currency == "SEK" }!
        #expect(sek.monthly == 200)
        #expect(sek.yearly == 2400)
        let usd = t.first { $0.currency == "USD" }!
        #expect(usd.monthly == 52)
        #expect(usd.yearly == 624)
    }

    @Test func alertsTwoDaysBeforeOnce() {
        let now = day(2026, 10, 28)
        var soon = Subscription(name: "Soon", price: 1, nextRenewal: day(2026, 10, 30))
        let later = Subscription(name: "Later", price: 1, nextRenewal: day(2026, 10, 31))
        #expect(Subscriptions.due([soon, later], now: now, cal).map(\.name) == ["Soon"])
        soon.alertedFor = soon.nextRenewal
        #expect(Subscriptions.due([soon, later], now: now, cal).isEmpty)
        #expect(Subscriptions.daysUntil(day(2026, 10, 30), now: now, cal) == 2)
    }

    // MARK: Orbit's moods

    @Test func budgetPaceSetsOrbitsFace() {
        #expect(BudgetData.monthFraction(day(2026, 11, 15), cal) == 0.5)
        #expect(BudgetData.monthFraction(day(2026, 10, 31), cal) == 1)
        #expect(BudgetPace.of(spent: 0, budget: 8000, monthFraction: 0.5) == .fresh)
        #expect(BudgetPace.of(spent: 3000, budget: 8000, monthFraction: 0.5) == .onTrack)
        #expect(BudgetPace.of(spent: 4400, budget: 8000, monthFraction: 0.5) == .onTrack)   // a little ahead is fine
        #expect(BudgetPace.of(spent: 5000, budget: 8000, monthFraction: 0.5) == .fast)
        #expect(BudgetPace.of(spent: 7300, budget: 8000, monthFraction: 0.95) == .nearlyOut)
        #expect(BudgetPace.of(spent: 8000, budget: 8000, monthFraction: 1) == .nearlyOut)
        #expect(BudgetPace.of(spent: 8001, budget: 8000, monthFraction: 0.2) == .over)
        #expect(BudgetPace.onTrack.orbit.mood == .happy)
        #expect(BudgetPace.fast.orbit.mood == .wide)
        #expect(BudgetPace.over.orbit.mood == .grumpy && BudgetPace.over.orbit.motion == .alert)
    }

    @Test func subscriptionOrbitNudgesBeforeRenewal() {
        #expect(Subscriptions.orbit(daysUntil: nil) == .happy)
        #expect(Subscriptions.orbit(daysUntil: 0).motion == .nudge)
        #expect(Subscriptions.orbit(daysUntil: 2).motion == .nudge)
        #expect(Subscriptions.orbit(daysUntil: 3).motion == .idle && Subscriptions.orbit(daysUntil: 3).mood == .normal)
        #expect(Subscriptions.orbit(daysUntil: 20) == .happy)
    }

    @Test func marketMoodFollowsTheList() {
        #expect(MarketMood.of([]).direction == .unknown)
        #expect(MarketMood.of([1.67, 2.19, -0.53, -0.19]).direction == .up)
        #expect(MarketMood.of([0.1, -0.2]).direction == .flat)
        #expect(MarketMood.of([-1, -2]).direction == .down)
        #expect(MarketMood.of([1, 2]).orbit.mood == .happy)
        #expect(MarketMood.of([4, 5]).orbit.motion == .celebrate)
        #expect(MarketMood.of([-1, -2]).orbit.mood == .wide)
        #expect(MarketMood.of([-4, -5]).orbit.motion == .alert)
        #expect(MarketMood.of([2, 4]).average == 3)
    }
}
