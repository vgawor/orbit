import SwiftUI

/// The pure part of Weather: Open-Meteo URLs, parsing and what the weather codes mean.
enum WeatherLogic {
    struct Place: Codable, Equatable, Identifiable {
        let name: String
        var region: String?
        var country: String?
        let latitude: Double
        let longitude: Double
        var id: String { "\(name)·\(latitude)·\(longitude)" }
        /// "Uppsala, Sweden"
        var detail: String { [region, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }.joined(separator: ", ") }

        static let stockholm = Place(name: "Stockholm", region: "Stockholm", country: "Sweden", latitude: 59.3294, longitude: 18.0687)
    }

    struct Hour: Codable, Equatable, Identifiable {
        /// Local time, "2026-10-28T15:00".
        let time: String
        let temperature: Double
        let code: Int
        var id: String { time }
        /// "15"
        var hourLabel: String { time.count >= 13 ? String(time.dropFirst(11).prefix(2)) : time }
    }

    struct Forecast: Codable, Equatable {
        let temperature: Double
        let code: Int
        let isDay: Bool
        let time: String
        let next: [Hour]
    }

    enum Sky: Equatable { case clear, partly, cloudy, fog, drizzle, rain, snow, thunder }

    /// What a WMO weather code means: a picture type, a few words and a symbol.
    static func sky(_ code: Int) -> Sky {
        switch code {
        case 0: .clear
        case 1, 2: .partly
        case 3: .cloudy
        case 45, 48: .fog
        case 51, 53, 55, 56, 57: .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: .rain
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 99: .thunder
        default: .cloudy
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear sky"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81: "Rain showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }

    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch sky(code) {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partly: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: code == 65 || code == 82 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        }
    }

    /// How heavy rain or snow is, 0…1, for the sky picture.
    static func intensity(_ code: Int) -> Double {
        switch code {
        case 51, 56, 61, 66, 71, 80, 85: 0.35
        case 53, 63, 73, 81, 77, 95: 0.65
        case 55, 57, 65, 67, 75, 82, 86, 96, 99: 1
        default: 0
        }
    }

    static func geocodeURL(_ query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "5"),
                        .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        return c.url
    }

    static func forecastURL(_ place: Place) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        // Two days, so "the next 8 hours" still works late in the evening.
        c.queryItems = [.init(name: "latitude", value: String(format: "%.4f", place.latitude)),
                        .init(name: "longitude", value: String(format: "%.4f", place.longitude)),
                        .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                        .init(name: "hourly", value: "temperature_2m,weather_code"),
                        .init(name: "forecast_days", value: "2"),
                        .init(name: "timezone", value: "auto")]
        return c.url!
    }

    private struct GeoResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    static func parsePlaces(_ data: Data) throws -> [Place] {
        try JSONDecoder().decode(GeoResponse.self, from: data).results?.map {
            Place(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude)
        } ?? []
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
        }
        let current: Current
        let hourly: Hourly?
    }

    static func parseForecast(_ data: Data, hours: Int = 8) throws -> Forecast {
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        var next: [Hour] = []
        if let h = r.hourly {
            // Times are local ISO strings of the same shape, so they sort as text.
            for i in h.time.indices where h.time[i] > r.current.time && next.count < hours {
                guard i < h.temperature_2m.count, i < h.weather_code.count,
                      let t = h.temperature_2m[i], let c = h.weather_code[i] else { continue }
                next.append(Hour(time: h.time[i], temperature: t, code: c))
            }
        }
        return Forecast(temperature: r.current.temperature_2m, code: r.current.weather_code,
                        isDay: r.current.is_day == 1, time: r.current.time, next: next)
    }

    /// "12°", "−3°"
    static func degrees(_ t: Double) -> String {
        let n = Int(t.rounded())
        return n < 0 ? "−\(-n)°" : "\(n)°"
    }

    static let sample = Forecast(temperature: 9.4, code: 2, isDay: true, time: "2026-10-28T13:00", next: [
        Hour(time: "2026-10-28T14:00", temperature: 10, code: 2), Hour(time: "2026-10-28T15:00", temperature: 10, code: 3),
        Hour(time: "2026-10-28T16:00", temperature: 9, code: 3), Hour(time: "2026-10-28T17:00", temperature: 8, code: 61),
        Hour(time: "2026-10-28T18:00", temperature: 8, code: 63), Hour(time: "2026-10-28T19:00", temperature: 7, code: 61),
        Hour(time: "2026-10-28T20:00", temperature: 6, code: 3), Hour(time: "2026-10-28T21:00", temperature: 5, code: 0),
    ])
}

/// Weather: an animated sky for one city and the next few hours.
@MainActor
@Observable
final class WeatherAddOn: AddOnModule {
    let id = "addon.weather"
    let title = "Weather"
    let symbol = "cloud.sun.fill"
    let addOn = AddOnInfo(category: .fun, tier: .free,
                          summary: "A live sky for your city, with the next few hours at a glance.")

    enum Status: Equatable { case idle, loading, failed(String) }

    private struct Saved: Codable {
        var place: WeatherLogic.Place
        var forecast: WeatherLogic.Forecast?
        var updated: Date?
    }

    private(set) var place: WeatherLogic.Place
    private(set) var forecast: WeatherLogic.Forecast?
    private(set) var updated: Date?
    private(set) var status = Status.idle

    var query = ""
    private(set) var results: [WeatherLogic.Place] = []
    private(set) var searching = false
    private(set) var searchMessage: String?
    var showingSearch = false

    private var timer: Timer?
    private var refreshing = false
    private let openPanel: @MainActor (String) -> Void

    init(openPanel: @escaping @MainActor (String) -> Void) {
        self.openPanel = openPanel
        let saved = Storage.load(Saved.self, from: "addon-weather")
        place = saved?.place ?? .stockholm
        forecast = saved?.forecast
        updated = saved?.updated
        if ModuleRegistry.isPreview { place = .stockholm; forecast = WeatherLogic.sample; updated = .now }
    }

    private func save() { Storage.save(Saved(place: place, forecast: forecast, updated: updated), to: "addon-weather") }

    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        guard !refreshing, !ModuleRegistry.isPreview else { return }
        refreshing = true
        defer { refreshing = false }
        if forecast == nil { status = .loading }
        let current = place
        var req = URLRequest(url: WeatherLogic.forecastURL(current), timeoutInterval: 15)
        req.setValue("Orbit-notch-app/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { status = .failed("The weather service didn't answer."); return }
            let f = try WeatherLogic.parseForecast(data)
            guard current == place else { return } // the city changed while loading
            forecast = f
            updated = .now
            status = .idle
            save()
        } catch {
            status = .failed("Can't reach the weather service.")
        }
    }

    func search() async {
        guard let url = WeatherLogic.geocodeURL(query) else { return }
        searching = true
        searchMessage = nil
        defer { searching = false }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Orbit-notch-app/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            results = try WeatherLogic.parsePlaces(data)
            if results.isEmpty { searchMessage = "No places called “\(query)”." }
        } catch {
            results = []
            searchMessage = "Can't search right now."
        }
    }

    func choose(_ new: WeatherLogic.Place) {
        place = new
        forecast = nil
        updated = nil
        results = []
        query = ""
        showingSearch = false
        save()
        Task { await refresh() }
    }

    var peekChip: PeekChip? {
        guard let forecast else { return nil }
        return PeekChip(symbol: WeatherLogic.symbol(forecast.code, isDay: forecast.isDay),
                        text: "\(WeatherLogic.degrees(forecast.temperature)) \(place.name)",
                        tint: .white, priority: 1)
    }

    var homeCard: AnyView? {
        guard let forecast else { return nil }
        return AnyView(Button { self.openPanel(self.id) } label: {
            NotchCard {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel(place.name)
                        Text(WeatherLogic.degrees(forecast.temperature)).font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(WeatherLogic.describe(forecast.code)).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    WeatherOrbitScene(code: forecast.code, isDay: forecast.isDay, orbitSize: 46,
                                      anchor: UnitPoint(x: 0.58, y: 0.62), fps: 24)
                        .frame(width: 112, height: 78)
                        .padding(.vertical, -6)
                }
            }
        }
        .buttonStyle(.plain))
    }

    var panel: AnyView { AnyView(WeatherPanel(model: self)) }
}

// MARK: - Views

private struct WeatherPanel: View {
    @Bindable var model: WeatherAddOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AddOnHeader(symbol: "cloud.sun.fill", title: "Weather", subtitle: subtitle, tint: .funTint)
                GlassPillButton(title: model.showingSearch ? "Done" : "Change city",
                                symbol: model.showingSearch ? "checkmark" : "magnifyingglass") {
                    withAnimation(Tokens.spring) { model.showingSearch.toggle() }
                }
            }
            if model.showingSearch {
                search
            } else if let forecast = model.forecast {
                header(forecast)
                hours(forecast)
            } else {
                empty
            }
        }
    }

    private var subtitle: String {
        if let updated = model.updated { return "Updated \(updated.formatted(date: .omitted, time: .shortened))" }
        return model.place.detail.isEmpty ? model.place.name : model.place.detail
    }

    private func header(_ f: WeatherLogic.Forecast) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                WeatherOrbitScene(code: f.code, isDay: f.isDay, orbitSize: min(geo.size.height * 0.5, 136), sky: true,
                                  anchor: UnitPoint(x: 0.72, y: 0.58))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.place.name).font(.system(size: 15, weight: .semibold))
                Text(WeatherLogic.degrees(f.temperature))
                    .font(.system(size: 54, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text(WeatherLogic.describe(f.code))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .glassSurface(Capsule())
                    .padding(.top, 2)
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Tokens.stroke))
    }

    private func hours(_ f: WeatherLogic.Forecast) -> some View {
        HStack(spacing: 0) {
            if f.next.isEmpty {
                Text("No hourly forecast yet.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(f.next) { hour in
                VStack(spacing: 7) {
                    Text(hour.hourLabel).font(.system(size: 11)).foregroundStyle(Tokens.secondary).monospacedDigit()
                    Image(systemName: WeatherLogic.symbol(hour.code, isDay: isDay(hour)))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17))
                        .frame(height: 22)
                    Text(WeatherLogic.degrees(hour.temperature)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .glassCard(22)
    }

    /// A rough guess for the strip's icons: day between 07 and 18.
    private func isDay(_ hour: WeatherLogic.Hour) -> Bool {
        let h = Int(hour.hourLabel) ?? 12
        return (7...18).contains(h)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            switch model.status {
            case .failed(let message):
                OrbitView(size: 54, mood: .squint, motion: reduceMotion ? .still : .idle, gaze: CGVector(dx: 0.4, dy: -0.8))
                Text(message).font(.system(size: 14, weight: .medium))
                Text("Orbit can't see the sky from here.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                GlassPillButton(title: "Try again", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                    .padding(.top, 2)
            default:
                OrbitView(size: 54, motion: reduceMotion ? .still : .thinking)
                Text("Checking the sky over \(model.place.name)…").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(22)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.secondary)
                TextField("Search for a city", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { Task { await model.search() } }
                if model.searching { ProgressView().controlSize(.small) }
                PillButton(title: "Search") { Task { await model.search() } }
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .glassSurface(Capsule())

            NotchScroll {
                VStack(spacing: 4) {
                    ForEach(model.results) { result in
                        Button { model.choose(result) } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(Color.funTint)
                                Text(result.name).font(.system(size: 13, weight: .medium))
                                Text(result.detail).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let message = model.searchMessage {
                        Text(message).font(.system(size: 12)).foregroundStyle(Tokens.secondary).padding(.top, 8)
                    } else if model.results.isEmpty {
                        VStack(spacing: 6) {
                            Text("Now showing \(model.place.name)").font(.system(size: 13, weight: .medium))
                            Text("Type a city and press Search.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        }
                        .padding(.top, 30)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(22)
    }
}

/// The animated sky: day or night colours, the sun or moon, drifting clouds and rain, snow or lightning.
/// As a `backdrop` (behind Orbit's weather scene) it keeps to the colours, stars, fog and a few faint far-off clouds.
struct WeatherSky: View {
    let code: Int
    let isDay: Bool
    var backdrop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in Self.paint(&ctx, size: size, t: t, code: code, isDay: isDay, backdrop: backdrop) }
        }
    }

    static func paint(_ ctx: inout GraphicsContext, size: CGSize, t: Double, code: Int, isDay: Bool, backdrop: Bool) {
        let sky = WeatherLogic.sky(code)
        let grey = [.cloudy, .fog, .rain, .drizzle, .thunder, .snow].contains(sky)
        let top: Color, bottom: Color
        switch (isDay, grey) {
        case (true, false): top = Color(red: 0.2, green: 0.5, blue: 0.95); bottom = Color(red: 0.55, green: 0.78, blue: 1)
        case (true, true): top = Color(red: 0.36, green: 0.43, blue: 0.54); bottom = Color(red: 0.6, green: 0.66, blue: 0.74)
        case (false, false): top = Color(red: 0.03, green: 0.05, blue: 0.18); bottom = Color(red: 0.16, green: 0.14, blue: 0.38)
        case (false, true): top = Color(red: 0.07, green: 0.08, blue: 0.13); bottom = Color(red: 0.2, green: 0.22, blue: 0.3)
        }
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // Stars at night when it's clear-ish.
        if !isDay, !grey {
            for i in 0..<40 {
                let x = hash(Double(i) * 2.3) * size.width, y = hash(Double(i) * 5.1 + 3) * size.height * 0.75
                let a = 0.4 + 0.4 * sin(t * (0.6 + hash(Double(i)) * 1.5) + Double(i))
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(a)))
            }
        }

        // Sun or moon, top right.
        let body = CGPoint(x: size.width * 0.8, y: size.height * 0.34)
        if sky != .fog, !backdrop {
            let dim = grey ? 0.45 : 1
            if isDay {
                let pulse = 1 + 0.04 * sin(t * 1.2)
                for (r, a) in [(70.0, 0.12), (50.0, 0.2)] {
                    let rr = r * pulse
                    ctx.fill(Path(ellipseIn: CGRect(x: body.x - rr, y: body.y - rr, width: rr * 2, height: rr * 2)),
                             with: .color(Color(red: 1, green: 0.9, blue: 0.5).opacity(a * dim)))
                }
                // Slowly turning rays.
                var rays = Path()
                for i in 0..<12 {
                    let a = Double(i) / 12 * 2 * .pi + t * 0.15
                    rays.move(to: CGPoint(x: body.x + 36 * cos(a), y: body.y + 36 * sin(a)))
                    rays.addLine(to: CGPoint(x: body.x + 46 * cos(a), y: body.y + 46 * sin(a)))
                }
                ctx.stroke(rays, with: .color(Color(red: 1, green: 0.88, blue: 0.45).opacity(0.7 * dim)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: body.x - 28, y: body.y - 28, width: 56, height: 56)),
                         with: .color(Color(red: 1, green: 0.85, blue: 0.35).opacity(dim)))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: body.x - 40, y: body.y - 40, width: 80, height: 80)),
                         with: .color(Color(red: 0.85, green: 0.88, blue: 1).opacity(0.1 * dim)))
                var moon = Path(ellipseIn: CGRect(x: body.x - 24, y: body.y - 24, width: 48, height: 48))
                moon = moon.subtracting(Path(ellipseIn: CGRect(x: body.x - 12, y: body.y - 32, width: 48, height: 48)))
                ctx.fill(moon, with: .color(Color(red: 0.95, green: 0.94, blue: 0.85).opacity(dim)))
            }
        }

        // Clouds drifting left to right and wrapping round.
        let clouds: Int = switch sky {
        case .clear: 0
        case .partly: 2
        case .fog: 0
        default: 4
        }
        for i in 0..<clouds {
            let speed = 6 + Double(i) * 3
            let span = size.width + 220
            let x = ((Double(i) + 0.15) / Double(clouds) * span + hash(Double(i) + 11) * 60 + t * speed).truncatingRemainder(dividingBy: span) - 110
            let y = size.height * (0.16 + 0.17 * Double(i % 3))
            let scale = 0.8 + hash(Double(i) + 4) * 0.6
            let shade = grey ? (isDay ? 0.88 : 0.42) : (isDay ? 1 : 0.6)
            let alpha = (grey ? 0.85 : 0.92) * (backdrop ? 0.4 : 1)
            drawCloud(&ctx, at: CGPoint(x: x, y: y), scale: backdrop ? scale * 0.7 : scale, color: Color(white: shade).opacity(alpha))
        }

        // Fog: soft bands sliding slowly.
        if sky == .fog {
            for i in 0..<5 {
                let y = size.height * (0.2 + Double(i) * 0.15)
                let shift = sin(t * 0.3 + Double(i)) * 30
                ctx.fill(Path(roundedRect: CGRect(x: -40 + shift, y: y, width: size.width + 80, height: 16), cornerRadius: 8),
                         with: .color(.white.opacity(0.18)))
            }
        }

        // Rain, drizzle, snow and lightning are Orbit's to act out when it's in front.
        if backdrop { return }
        // Rain, drizzle and snow.
        let amount = WeatherLogic.intensity(code)
        if [.rain, .drizzle, .thunder].contains(sky) {
            let count = Int(30 + 70 * max(amount, 0.3))
            var drops = Path()
            for i in 0..<count {
                let x = hash(Double(i) * 1.7) * (size.width + 40) - 20
                let speed = 260 + hash(Double(i) + 9) * 120
                let y = (hash(Double(i) * 3.3) * size.height + t * speed).truncatingRemainder(dividingBy: size.height + 30) - 15
                let len = sky == .drizzle ? 5.0 : 11.0
                drops.move(to: CGPoint(x: x, y: y))
                drops.addLine(to: CGPoint(x: x - len * 0.25, y: y + len))
            }
            ctx.stroke(drops, with: .color(Color(red: 0.75, green: 0.85, blue: 1).opacity(0.65)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        if sky == .snow {
            let count = Int(30 + 60 * max(amount, 0.3))
            for i in 0..<count {
                let speed = 22 + hash(Double(i) + 2) * 26
                let y = (hash(Double(i) * 4.1) * size.height + t * speed).truncatingRemainder(dividingBy: size.height + 10) - 5
                let x = hash(Double(i) * 1.3) * size.width + sin(t * 0.9 + Double(i)) * 8
                let r = 1.4 + hash(Double(i) + 7) * 1.8
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.85)))
            }
        }
        // Lightning: a short flash every few seconds.
        if sky == .thunder {
            let phase = t.truncatingRemainder(dividingBy: 4.5)
            if phase < 0.18 {
                ctx.fill(Path(rect), with: .color(.white.opacity(0.35 * (1 - phase / 0.18))))
                var bolt = Path()
                let x0 = size.width * 0.35
                bolt.move(to: CGPoint(x: x0, y: size.height * 0.25))
                bolt.addLine(to: CGPoint(x: x0 - 12, y: size.height * 0.5))
                bolt.addLine(to: CGPoint(x: x0 + 4, y: size.height * 0.5))
                bolt.addLine(to: CGPoint(x: x0 - 8, y: size.height * 0.78))
                ctx.stroke(bolt, with: .color(Color(red: 1, green: 0.95, blue: 0.6)), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
        }
    }

    private static func drawCloud(_ ctx: inout GraphicsContext, at p: CGPoint, scale s: Double, color: Color) {
        var cloud = Path()
        for (dx, dy, r) in [(-30.0, 6.0, 18.0), (-8, -8, 24), (18, -2, 20), (36, 8, 14)] {
            cloud.addEllipse(in: CGRect(x: p.x + (dx - r) * s, y: p.y + (dy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        cloud.addRoundedRect(in: CGRect(x: p.x - 44 * s, y: p.y + 2 * s, width: 92 * s, height: 20 * s), cornerSize: CGSize(width: 10 * s, height: 10 * s))
        ctx.fill(cloud, with: .color(color))
    }

    private static func hash(_ n: Double) -> Double {
        let x = sin(n * 12.9898) * 43758.5453
        return x - floor(x)
    }
}
