import Foundation
import Testing
@testable import Orbit

@MainActor
struct HomeAndMeetingsTests {
    @Test func homeRowsPackByWidth() {
        let p = HomeGrid.arrange([1, 0.5, 0.5, 1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 1], width: 600, spacing: 10)
        #expect(p.map(\.row) == [0, 1, 1, 2, 2, 2, 3, 4])
        #expect(p[0].width == 600)
        #expect(p[1].width == 295 && p[2].x == 305)
        // Three thirds fill the row exactly: 193.33 + 10 + 193.33 + 10 + 193.33.
        #expect(abs(p[5].x + p[5].width - 600) < 0.01)
        // A half after a third doesn't fit with two more thirds: a third and a half share a row.
        let mixed = HomeGrid.arrange([1.0 / 3, 0.5, 1.0 / 3], width: 600, spacing: 10)
        #expect(mixed.map(\.row) == [0, 0, 1])
    }

    @Test func homeOrderFollowsYourDrags() {
        #expect(Appearance.ordered(["greeting", "now", "bots", "addon:weather"], by: []) == ["greeting", "now", "bots", "addon:weather"])
        #expect(Appearance.ordered(["greeting", "now", "bots", "addon:weather"], by: ["bots", "greeting"]) == ["bots", "greeting", "now", "addon:weather"])
        #expect(Appearance.ordered(["now"], by: ["gone", "now"]) == ["now"])
    }

    @Test func meetingTimesReadNaturally() {
        #expect(Meeting.span(20 * 60) == "20 min")
        #expect(Meeting.span(135 * 60) == "2 h 15 min")
        #expect(Meeting.span(120 * 60) == "2 h")
        #expect(Meeting.span(27 * 3600) == "1 d 3 h")
        #expect(Meeting.span(5) == "1 min")
        #expect(Meeting.longEvent == 8 * 3600)
    }

    @Test func tabsMoveWhereYouDropThem() {
        let key = "pinnedTabs"
        let before = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.set(["music", "meetings", "tasks", "focus"], forKey: key)
        let registry = ModuleRegistry(modules: [])
        registry.movePinned("focus", to: "meetings")
        #expect(UserDefaults.standard.stringArray(forKey: key) == ["music", "focus", "meetings", "tasks"])
        registry.movePinned("music", to: "tasks")
        #expect(UserDefaults.standard.stringArray(forKey: key) == ["focus", "meetings", "tasks", "music"])
        registry.movePinned("nope", to: "tasks")
        #expect(UserDefaults.standard.stringArray(forKey: key) == ["focus", "meetings", "tasks", "music"])
    }

    @Test func botsWidgetIsOnHomeAndSizesDefaultSensibly() {
        #expect(Appearance.Widget.allCases.contains(.bots))
        let look = Appearance.shared
        if look.homeSizes["bots"] == nil { #expect(look.size(of: "bots") == .half) }
        if look.homeSizes["addon:weather"] == nil { #expect(look.size(of: "addon:weather") == .half) }
        if look.homeSizes["now"] == nil { #expect(look.size(of: "now") == .full) }
        #expect(Appearance.HomeSize.third.fraction < Appearance.HomeSize.half.fraction)
    }

    @Test func canvasFramesSnapAndStayInside() {
        typealias F = Appearance.HomeFrame
        // Snaps to 1/24 of the width and 8 pt rows.
        let f = F(x: 0.26, y: 13, w: 0.49, h: 101).snapped()
        #expect(abs(f.x - 6.0 / 24) < 0.0001)
        #expect(abs(f.w - 12.0 / 24) < 0.0001)
        #expect(f.y == 16 && f.h == 104)
        // Never smaller than the minimum, never past the right edge, never above the top.
        let tiny = F(x: 0.95, y: -30, w: 0.01, h: 5).snapped()
        #expect(tiny.w == F.minWidth && tiny.h == F.minHeight)
        #expect(tiny.x + tiny.w <= 1.0001)
        #expect(tiny.y == 0)
        #expect(F(x: -0.2, y: 0, w: 2, h: 80).snapped() == F(x: 0, y: 0, w: 1, h: 80))
    }

    @Test func canvasFramesAreSaved() throws {
        let frames = ["bots": Appearance.HomeFrame(x: 0.5, y: 120, w: 0.5, h: 200)]
        let back = try JSONDecoder().decode([String: Appearance.HomeFrame].self, from: JSONEncoder().encode(frames))
        #expect(back == frames)
    }

    @Test func dashboardNeverOverlapsAndClosesGaps() {
        typealias F = Appearance.HomeFrame
        func y(_ frames: [String: F], _ key: String) -> Double { frames[key]!.y }

        // A gap closes; side-by-side widgets stay side by side.
        var r = Appearance.resolve(["a": F(x: 0, y: 0, w: 0.5, h: 100), "b": F(x: 0.5, y: 0, w: 0.5, h: 100),
                                    "c": F(x: 0, y: 300, w: 0.5, h: 50)])
        #expect(y(r, "a") == 0 && y(r, "b") == 0 && y(r, "c") == 110)

        // Dropped on the top half of A: B takes A's spot and A moves down.
        r = Appearance.resolve(["a": F(x: 0, y: 0, w: 0.5, h: 100), "b": F(x: 0, y: 20, w: 0.5, h: 80)], moved: "b")
        #expect(y(r, "b") == 0 && y(r, "a") == 90)
        // Dropped on the bottom half: B goes under A.
        r = Appearance.resolve(["a": F(x: 0, y: 0, w: 0.5, h: 100), "b": F(x: 0, y: 70, w: 0.5, h: 80)], moved: "b")
        #expect(y(r, "a") == 0 && y(r, "b") == 110)

        // A wide widget lands under the taller of the two above it.
        r = Appearance.resolve(["a": F(x: 0, y: 0, w: 0.5, h: 100), "b": F(x: 0.5, y: 0, w: 0.5, h: 150),
                                "f": F(x: 0, y: 40, w: 1, h: 80)])
        #expect(y(r, "f") == 160)

        // Nothing ever overlaps, whatever comes in.
        let messy: [String: F] = ["a": F(x: 0, y: 0, w: 0.5, h: 120), "b": F(x: 0.25, y: 10, w: 0.5, h: 60),
                                  "c": F(x: 0.5, y: 5, w: 0.5, h: 200), "d": F(x: 0, y: 0, w: 1, h: 40)]
        let out = Appearance.resolve(messy, moved: "b")
        for (k1, f1) in out { for (k2, f2) in out where k1 < k2 {
            let side = f1.x < f2.x + f2.w - 0.001 && f2.x < f1.x + f1.w - 0.001
            let stacked = f1.y < f2.y + f2.h && f2.y < f1.y + f1.h
            #expect(!(side && stacked), "\(k1) and \(k2) overlap")
        } }
    }
}
