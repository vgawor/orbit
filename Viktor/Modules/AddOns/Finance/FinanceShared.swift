import AppKit
import SwiftUI

// MARK: - Money maths (pure, tested)

enum Money {
    /// Reads what people type: "1 234,50", "1234.50", "1,234.50", "250 kr". Nil when there's no number.
    static func parse(_ text: String) -> Decimal? {
        var s = text.filter { "0123456789,.-".contains($0) }
        guard s.contains(where: \.isNumber) else { return nil }
        let lastComma = s.lastIndex(of: ","), lastDot = s.lastIndex(of: ".")
        // Whichever separator comes last is the decimal one; the other groups thousands.
        if let c = lastComma, let d = lastDot {
            if c > d { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else if lastComma != nil {
            // One comma is a decimal comma (Swedish); several group thousands ("1,234,567").
            if s.filter({ $0 == "," }).count > 1 { s = s.replacingOccurrences(of: ",", with: "") }
            else { s = s.replacingOccurrences(of: ",", with: ".") }
        } else if lastDot != nil, s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Rounds to `scale` decimals (half up), for money.
    static func round(_ value: Decimal, _ scale: Int = 2) -> Decimal {
        var v = value, out = Decimal()
        NSDecimalRound(&out, &v, scale, .plain)
        return out
    }

    static func decimal(_ d: Double) -> Decimal { Decimal(string: String(format: "%.10f", d)) ?? Decimal(d) }

    static func double(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    /// "1 234,50 kr" — the currency's own style, in the user's locale.
    static func format(_ value: Decimal, _ code: String, decimals: Int? = nil) -> String {
        let places = decimals ?? (code == "JPY" ? 0 : 2)
        return value.formatted(.currency(code: code).precision(.fractionLength(places)))
    }

    /// Like `format`, but whole amounts drop the decimals ("129 kr", "12,50 €").
    static func smart(_ value: Decimal, _ code: String) -> String {
        format(value, code, decimals: Money.round(value, 0) == value ? 0 : nil)
    }

    /// A number without a currency, for copying and for rates ("11,4721").
    static func plain(_ value: Decimal, decimals: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }

    /// A price that might be tiny (crypto) or large: more decimals for small numbers.
    static func price(_ value: Double, _ code: String) -> String {
        let places = value >= 1000 ? 0 : value >= 1 ? 2 : 4
        return Money.format(decimal(value), code, decimals: places)
    }

    /// "+1,2 %" / "−0,4 %".
    static func change(_ pct: Double) -> String {
        let sign = pct > 0 ? "+" : pct < 0 ? "−" : ""
        return sign + abs(pct).formatted(.number.precision(.fractionLength(pct.magnitude < 10 ? 2 : 1))) + " %"
    }
}

// MARK: - Frankfurter (ECB rates, no key)

/// One day of ECB rates, relative to `base`.
struct FXRates: Codable, Equatable {
    var base: String
    var date: String
    var rates: [String: Double]

    /// Rate for 1 `code` in base units' terms: base itself is 1.
    func rate(_ code: String) -> Double? { code == base ? 1 : rates[code] }

    /// All currencies these rates can convert, base included, sorted.
    var codes: [String] { Array(Set(rates.keys).union([base])).sorted() }

    /// How many `to` you get for `amount` `from`. Nil when a currency is missing.
    func convert(_ amount: Decimal, from: String, to: String) -> Decimal? {
        guard let f = rate(from), let t = rate(to), f > 0 else { return nil }
        return amount * Money.decimal(t / f)
    }

    /// 1 `from` in `to`.
    func cross(_ from: String, _ to: String) -> Double? {
        guard let f = rate(from), let t = rate(to), f > 0 else { return nil }
        return t / f
    }
}

enum Frankfurter {
    static let latestURL = URL(string: "https://api.frankfurter.app/latest?from=EUR")!

    /// `/latest` → rates.
    static func parseLatest(_ data: Data) -> FXRates? {
        struct R: Decodable { let base: String; let date: String; let rates: [String: Double] }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return FXRates(base: r.base, date: r.date, rates: r.rates)
    }

    /// `/<start>..` → each day's rates, oldest first.
    static func parseSeries(_ data: Data) -> [FXRates] {
        struct R: Decodable { let base: String; let rates: [String: [String: Double]] }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return r.rates.keys.sorted().map { FXRates(base: r.base, date: $0, rates: r.rates[$0] ?? [:]) }
    }

    static func seriesURL(since start: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Berlin"); f.dateFormat = "yyyy-MM-dd"
        return URL(string: "https://api.frankfurter.app/\(f.string(from: start))..?from=EUR")!
    }

    static func latest() async throws -> FXRates {
        let data = try await FinanceNet.get(latestURL)
        guard let r = parseLatest(data) else { throw FinanceNet.Failure.badData }
        return r
    }

    /// The last two business days of rates (for a day's change).
    static func lastTwoDays(now: Date = .now) async throws -> [FXRates] {
        let start = Calendar.current.date(byAdding: .day, value: -8, to: now) ?? now
        let days = parseSeries(try await FinanceNet.get(seriesURL(since: start)))
        guard !days.isEmpty else { throw FinanceNet.Failure.badData }
        return Array(days.suffix(2))
    }

    /// Readable date: "28 Oct 2026".
    static func display(_ isoDate: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: isoDate) else { return isoDate }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

enum FinanceNet {
    enum Failure: LocalizedError {
        case offline, rateLimited, badData, http(Int)
        var errorDescription: String? {
            switch self {
            case .offline: "You seem to be offline."
            case .rateLimited: "Too many requests — trying again later."
            case .badData: "Got an answer we couldn't read."
            case .http(let code): "The server said \(code)."
            }
        }
    }

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.offline }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw Failure.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        }
        return data
    }
}

// MARK: - Shared look

enum FinanceUI {
    static let tint = AddOnCategory.finance.tint

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Currencies shown first, before the rest the API knows.
    static let common = ["SEK", "EUR", "USD", "GBP", "NOK", "DKK", "CHF", "JPY", "PLN", "CAD", "AUD"]

    static func ordered(_ codes: [String]) -> [String] {
        common.filter { codes.contains($0) || codes.isEmpty } + codes.filter { !common.contains($0) }.sorted()
    }
}

/// A plain text field on a glass capsule.
struct FinanceField: View {
    let placeholder: String
    @Binding var text: String
    var size: CGFloat = 13
    var height: CGFloat = 32
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: size > 16 ? .semibold : .regular).monospacedDigit())
            .padding(.horizontal, 12).frame(height: height)
            .glassSurface(Capsule())
            .onSubmit(onSubmit)
    }
}

/// A small selectable capsule (categories, rates, cycles).
struct FinanceChip: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    var tint: Color = .white
    var stretch = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? tint : Tokens.secondary) }
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(maxWidth: stretch ? .infinity : nil).frame(height: 26)
            .foregroundStyle(selected ? .white : Tokens.secondary)
            .background { if selected { Capsule().fill(Color.white.opacity(0.17)) } }
            .glassSurface(Capsule(), selected: selected)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A grid of currency codes to pick one from (shown inline, so it works everywhere).
struct CurrencyGrid: View {
    let codes: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        NotchScroll {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(codes, id: \.self) { code in
                    Button { pick(code) } label: {
                        Text(code).font(.system(size: 11.5, weight: .semibold).monospaced())
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .foregroundStyle(code == selected ? .black : .white)
                            .background { if code == selected { Capsule().fill(.white) } }
                            .glassSurface(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
        }
    }
}

/// A small round icon button (copy, delete, swap).
struct FinanceIconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(.white)
                .glassSurface(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Copy a value, and show a tick for a moment.
struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        FinanceIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy \(value)", size: 24) {
            FinanceUI.copy(value)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
    }
}
