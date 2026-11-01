import Foundation
import Testing
@testable import Orbit

@Suite("Fun add-ons: Decide")
struct DecideLogicTests {
    @Test func sameSeedSameResults() {
        var a = FunSeededRandom(seed: 42), b = FunSeededRandom(seed: 42)
        #expect((0..<20).map { _ in DecideLogic.flip(using: &a) } == (0..<20).map { _ in DecideLogic.flip(using: &b) })
    }

    @Test func coinGivesBothSides() {
        var rng = FunSeededRandom(seed: 1)
        let flips = (0..<200).map { _ in DecideLogic.flip(using: &rng) }
        #expect(flips.contains(true) && flips.contains(false))
    }

    @Test func diceStayInRange() {
        var rng = FunSeededRandom(seed: 7)
        for _ in 0..<500 {
            let d6 = DecideLogic.roll(.d6, using: &rng)
            #expect(d6.count == 1 && (1...6).contains(d6[0]))
            let d20 = DecideLogic.roll(.d20, using: &rng)
            #expect(d20.count == 1 && (1...20).contains(d20[0]))
            let two = DecideLogic.roll(.twoD6, using: &rng)
            #expect(two.count == 2 && two.allSatisfy { (1...6).contains($0) })
        }
    }

    @Test func d20ReachesBothEnds() {
        var rng = FunSeededRandom(seed: 3)
        let rolls = Set((0..<2000).map { _ in DecideLogic.roll(.d20, using: &rng)[0] })
        #expect(rolls == Set(1...20))
    }

    @Test func parsesCommasAndLines() {
        #expect(DecideLogic.options(from: "Pizza, Sushi ,\nTacos\n\n ,Ramen") == ["Pizza", "Sushi", "Tacos", "Ramen"])
        #expect(DecideLogic.options(from: "  , \n ").isEmpty)
        #expect(DecideLogic.options(from: "Just one") == ["Just one"])
    }

    @Test func pickHandlesEmpty() {
        var rng = FunSeededRandom(seed: 9)
        #expect(DecideLogic.pick(from: 0, using: &rng) == nil)
        for _ in 0..<100 { #expect((0..<3).contains(DecideLogic.pick(from: 3, using: &rng)!)) }
    }

    @Test func spinSlowsDown() {
        let d = DecideLogic.spinDelays(steps: 10)
        #expect(d.count == 10)
        #expect(zip(d, d.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(DecideLogic.spinDelays(steps: 0).isEmpty)
    }

    @Test func pipsMatchValue() {
        for v in 1...6 { #expect(DecideLogic.pips(v).count == v) }
    }
}

@Suite("Fun add-ons: Star Catcher")
struct StarCatcherTests {
    private func game() -> StarCatcherGame {
        var g = StarCatcherGame()
        g.resize(width: 600, height: 300)
        g.start()
        return g
    }

    @Test func catchingAStarScores() {
        var g = game()
        g.items = [.init(id: 1, x: g.playerX, y: g.playerY - 2, kind: .star, size: 10)]
        var rng = FunSeededRandom(seed: 1)
        let events = g.step(dt: 0.001, using: &rng)
        #expect(events.contains(.caught))
        #expect(g.score == 1)
        #expect(g.lives == 3)
        #expect(!g.items.contains { $0.id == 1 })
    }

    @Test func meteorCostsALifeAndThreeEndTheGame() {
        var g = game()
        var rng = FunSeededRandom(seed: 2)
        for i in 0..<3 {
            g.items = [.init(id: 100 + i, x: g.playerX, y: g.playerY, kind: .meteor, size: 10)]
            g.step(dt: 0.001, using: &rng)
        }
        #expect(g.lives == 0)
        #expect(g.phase == .over)
        #expect(g.score == 0)
    }

    @Test func farAwayThingsMiss() {
        let g = game()
        let star = StarCatcherGame.Item(id: 1, x: g.playerX + 200, y: g.playerY, kind: .star, size: 10)
        #expect(!StarCatcherGame.reaches(star, playerX: g.playerX, playerY: g.playerY))
        let high = StarCatcherGame.Item(id: 2, x: g.playerX, y: 20, kind: .star, size: 10)
        #expect(!StarCatcherGame.reaches(high, playerX: g.playerX, playerY: g.playerY))
    }

    @Test func missedThingsFallOffTheBottom() {
        var g = game()
        g.items = [.init(id: 1, x: 10, y: 300 + 30, kind: .star, size: 10)]
        var rng = FunSeededRandom(seed: 3)
        g.step(dt: 0.001, using: &rng)
        #expect(!g.items.contains { $0.id == 1 })
        #expect(g.score == 0 && g.lives == 3)
    }

    @Test func speedRisesOverTime() {
        var g = game()
        let early = g.fallSpeed
        g.elapsed = 40
        #expect(g.fallSpeed > early)
        #expect(g.spawnEvery < StarCatcherGame().spawnEvery)
    }

    @Test func pausedGameDoesNotMove() {
        var g = game()
        g.items = [.init(id: 1, x: 100, y: 50, kind: .star, size: 10)]
        g.phase = .paused
        var rng = FunSeededRandom(seed: 4)
        g.step(dt: 0.5, using: &rng)
        #expect(g.items.first?.y == 50)
    }

    @Test func thingsSpawnAndFall() {
        var g = game()
        var rng = FunSeededRandom(seed: 5)
        for _ in 0..<60 { g.step(dt: 1.0 / 60, using: &rng) }
        #expect(!g.items.isEmpty)
    }

    @Test func playerStaysInField() {
        var g = game()
        g.movePlayer(dt: 5, keys: -1, target: nil)
        #expect(g.playerX >= 0)
        g.movePlayer(dt: 5, keys: 1, target: nil)
        #expect(g.playerX <= g.width)
        g.movePlayer(dt: 1, keys: 0, target: 120)
        #expect(abs(g.playerX - 120) < 1)
    }
}

@Suite("Fun add-ons: On this day")
struct OnThisDayTests {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func urlAndKeyUsePaddedMonthAndDay() {
        let date = utc.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        #expect(OnThisDayLogic.feedURL(for: date, calendar: utc).absoluteString
                == "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/selected/03/07")
        #expect(OnThisDayLogic.dayKey(for: date, calendar: utc) == "03-07")
    }

    @Test func parsesFeed() throws {
        let json = """
        {"selected":[
          {"text":"The Statue of Liberty is dedicated.","year":1886,
           "pages":[{"titles":{"normalized":"Statue of Liberty"},"content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Statue_of_Liberty"}}}]},
          {"text":"Something with no pages.","year":1971},
          {"text":"","year":1900},
          {"text":"No year here."}
        ]}
        """
        let events = try OnThisDayLogic.parse(Data(json.utf8))
        #expect(events.count == 2)
        #expect(events[0].year == 1971) // newest first
        #expect(events[1].title == "Statue of Liberty")
        #expect(events[1].url?.absoluteString == "https://en.wikipedia.org/wiki/Statue_of_Liberty")
        #expect(events[0].url == nil)
    }

    @Test func emptyOrBrokenFeed() throws {
        #expect(try OnThisDayLogic.parse(Data("{}".utf8)).isEmpty)
        #expect(throws: (any Error).self) { try OnThisDayLogic.parse(Data("not json".utf8)) }
    }

    @Test func windowWraps() {
        let e = (0..<5).map { OnThisDayLogic.Event(year: 2000 + $0, text: "e\($0)") }
        #expect(OnThisDayLogic.window(e, from: 3, count: 4).map(\.year) == [2003, 2004, 2000, 2001])
        #expect(OnThisDayLogic.window(Array(e.prefix(2)), from: 0, count: 4).count == 2)
        #expect(OnThisDayLogic.window([], from: 0, count: 4).isEmpty)
    }

    @Test func bcYears() {
        #expect(OnThisDayLogic.Event(year: -44, text: "x").yearText == "44 BC")
        #expect(OnThisDayLogic.Event(year: 1969, text: "x").yearText == "1969")
    }

    @Test func cacheIsPrunedButKeepsToday() {
        var days: [String: [OnThisDayLogic.Event]] = [:]
        for d in 1...12 { days[String(format: "01-%02d", d)] = [] }
        let pruned = OnThisDayLogic.pruned(days, keep: "01-01", limit: 5)
        #expect(pruned.count == 5)
        #expect(pruned["01-01"] != nil)
    }
}

@Suite("Fun add-ons: Weather")
struct WeatherLogicTests {
    @Test func codesMapToSkies() {
        #expect(WeatherLogic.sky(0) == .clear)
        #expect(WeatherLogic.sky(2) == .partly)
        #expect(WeatherLogic.sky(3) == .cloudy)
        #expect(WeatherLogic.sky(45) == .fog)
        #expect(WeatherLogic.sky(53) == .drizzle)
        #expect(WeatherLogic.sky(63) == .rain)
        #expect(WeatherLogic.sky(81) == .rain)
        #expect(WeatherLogic.sky(75) == .snow)
        #expect(WeatherLogic.sky(99) == .thunder)
        #expect(WeatherLogic.describe(0) == "Clear sky")
        #expect(WeatherLogic.describe(1234) == "Unknown")
        #expect(WeatherLogic.symbol(0, isDay: false) == "moon.stars.fill")
        #expect(WeatherLogic.symbol(0, isDay: true) == "sun.max.fill")
    }

    @Test func degreesUseARealMinus() {
        #expect(WeatherLogic.degrees(12.4) == "12°")
        #expect(WeatherLogic.degrees(-2.6) == "−3°")
        #expect(WeatherLogic.degrees(-0.2) == "0°")
    }

    @Test func geocodeURLIsEncoded() {
        #expect(WeatherLogic.geocodeURL("   ") == nil)
        let url = WeatherLogic.geocodeURL("São Paulo")!.absoluteString
        #expect(url.hasPrefix("https://geocoding-api.open-meteo.com/v1/search?name=S%C3%A3o%20Paulo&count=5"))
    }

    @Test func forecastURLHasEverything() {
        let url = WeatherLogic.forecastURL(.stockholm).absoluteString
        #expect(url.contains("latitude=59.3294"))
        #expect(url.contains("current=temperature_2m,weather_code,is_day"))
        #expect(url.contains("hourly=temperature_2m,weather_code"))
        #expect(url.contains("timezone=auto"))
    }

    @Test func parsesPlaces() throws {
        let json = """
        {"results":[{"id":1,"name":"Uppsala","latitude":59.86,"longitude":17.64,"country":"Sweden","admin1":"Uppsala"}]}
        """
        let places = try WeatherLogic.parsePlaces(Data(json.utf8))
        #expect(places.count == 1)
        #expect(places[0].name == "Uppsala")
        #expect(places[0].detail == "Sweden")
        #expect(try WeatherLogic.parsePlaces(Data("{\"generationtime_ms\":0.1}".utf8)).isEmpty)
    }

    @Test func parsesForecastAndTakesNextHours() throws {
        let times = (0..<24).map { String(format: "\"2026-10-28T%02d:00\"", $0) }.joined(separator: ",")
        let temps = (0..<24).map { "\(Double($0) / 2)" }.joined(separator: ",")
        let codes = (0..<24).map { $0 == 15 ? "61" : "3" }.joined(separator: ",")
        let json = """
        {"current":{"time":"2026-10-28T14:15","interval":900,"temperature_2m":8.4,"weather_code":2,"is_day":1},
         "hourly":{"time":[\(times)],"temperature_2m":[\(temps)],"weather_code":[\(codes)]}}
        """
        let f = try WeatherLogic.parseForecast(Data(json.utf8))
        #expect(f.temperature == 8.4)
        #expect(f.code == 2)
        #expect(f.isDay)
        #expect(f.next.count == 8)
        #expect(f.next.first?.hourLabel == "15")
        #expect(f.next.first?.code == 61)
        #expect(f.next.last?.hourLabel == "22")
    }

    @Test func lateEveningStillHasHoursFromTomorrow() throws {
        let json = """
        {"current":{"time":"2026-10-28T23:30","temperature_2m":1,"weather_code":71,"is_day":0},
         "hourly":{"time":["2026-10-28T23:00","2026-10-29T00:00","2026-10-29T01:00"],"temperature_2m":[1,0.5,null],"weather_code":[71,71,73]}}
        """
        let f = try WeatherLogic.parseForecast(Data(json.utf8))
        #expect(f.next.map(\.hourLabel) == ["00"]) // a missing value is skipped
        #expect(!f.isDay)
    }
}

@Suite("Fun add-ons: Fun fact")
struct FunFactTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func plentyOfShortFacts() {
        #expect(FunFactLogic.facts.count >= 75)
        #expect(FunFactLogic.facts.allSatisfy { $0.text.count <= 140 && $0.text.hasSuffix(".") })
        #expect(Set(FunFactLogic.facts.map(\.text)).count == FunFactLogic.facts.count)
    }

    @Test func sameFactAllDayNextOneTomorrow() {
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 7))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 23))!
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 7))!
        let n = FunFactLogic.facts.count
        let today = FunFactLogic.index(for: morning, count: n, calendar: cal)
        #expect(FunFactLogic.index(for: evening, count: n, calendar: cal) == today)
        #expect(FunFactLogic.index(for: tomorrow, count: n, calendar: cal) == (today + 1) % n)
    }

    @Test func indexAlwaysInRange() {
        let old = cal.date(from: DateComponents(year: 1990, month: 1, day: 1))!
        #expect((0..<10).contains(FunFactLogic.index(for: old, count: 10, calendar: cal)))
        #expect(FunFactLogic.index(for: .now, count: 0, calendar: cal) == 0)
    }
}

@Suite("Fun add-ons: catalog") @MainActor
struct FunCatalogTests {
    @Test func fiveFreeFunAddOns() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let modules = FunAddOns.make(ctx).compactMap { $0 as? any AddOnModule }
        #expect(modules.map(\.id) == ["addon.decide", "addon.arcade", "addon.onthisday", "addon.weather", "addon.funfact"])
        #expect(modules.allSatisfy { $0.addOn.category == .fun && $0.addOn.tier == .free })
    }
}

@Suite("Fun add-ons: Orbit in the weather")
struct WeatherOrbitSceneTests {
    @Test func codesMapToScenes() {
        #expect(WeatherLogic.scene(0, isDay: true) == .sunny)
        #expect(WeatherLogic.scene(0, isDay: false) == .night)
        #expect(WeatherLogic.scene(2, isDay: true) == .partly)
        #expect(WeatherLogic.scene(2, isDay: false) == .night)
        #expect(WeatherLogic.scene(3, isDay: false) == .cloudy)
        #expect(WeatherLogic.scene(45, isDay: true) == .fog)
        #expect(WeatherLogic.scene(53, isDay: true) == .rain)
        #expect(WeatherLogic.scene(82, isDay: false) == .rain)
        #expect(WeatherLogic.scene(75, isDay: true) == .snow)
        #expect(WeatherLogic.scene(99, isDay: true) == .thunder)
        #expect(WeatherLogic.scene(1234, isDay: true) == .cloudy)
    }

    @Test func orbitActsEachScene() {
        #expect(WeatherLogic.Scene.night.motion == .sleep)
        #expect(WeatherLogic.Scene.night.mood == .closed)
        #expect(WeatherLogic.Scene.sunny.motion == .glow)
        #expect(WeatherLogic.Scene.thunder.mood == .wide)
        for scene in WeatherLogic.Scene.allCases { #expect(!scene.line.isEmpty) }
    }
}
