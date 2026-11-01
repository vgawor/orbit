import SwiftUI
import Testing
@testable import Orbit

@MainActor
private final class FakeModule: NotchModule {
    let id: String
    let title: String
    let symbol = "circle"
    let showsTab: Bool
    var panel: AnyView { AnyView(EmptyView()) }
    init(_ id: String, tab: Bool = true) { self.id = id; title = id; showsTab = tab }
}

@MainActor
@Suite(.serialized)
struct PinnedTabsTests {
    private func registry(_ count: Int) -> ModuleRegistry {
        UserDefaults.standard.removeObject(forKey: "pinnedTabs")
        UserDefaults.standard.removeObject(forKey: "disabledModules")
        var mods: [any NotchModule] = (0..<count).map { FakeModule("m\($0)") }
        mods.append(FakeModule("background", tab: false))
        return ModuleRegistry(modules: mods)
    }

    @Test func firstEightBuiltInTabsArePinnedByDefault() {
        let r = registry(11)
        #expect(r.pinnedTabs.map(\.id) == (0..<8).map { "m\($0)" })
        #expect(r.launcherTabs.map(\.id) == ["m8", "m9", "m10"])
        #expect(!r.tabModules.contains { $0.id == "background" })
    }

    @Test func pinningIsRefusedWhenFullAndWorksAfterUnpinning() {
        let r = registry(10)
        #expect(r.pinsFull)
        #expect(!r.setPinned("m9", true))
        #expect(r.setPinned("m0", false))
        #expect(r.setPinned("m9", true))
        #expect(r.pinnedTabs.last?.id == "m9")
        #expect(r.launcherTabs.map(\.id) == ["m0", "m8"])
    }

    @Test func pinsAreSavedAndCanBeReordered() {
        let r = registry(3)
        r.movePinned("m0", by: 1)
        #expect(r.pinnedTabs.map(\.id) == ["m1", "m0", "m2"])
        let again = ModuleRegistry(modules: r.all)
        #expect(again.pinnedTabs.map(\.id) == ["m1", "m0", "m2"])
        UserDefaults.standard.removeObject(forKey: "pinnedTabs")
    }

    @Test func turnedOffModulesLeaveTheTabBar() {
        let r = registry(3)
        r.setEnabled("m1", false)
        #expect(r.pinnedTabs.map(\.id) == ["m0", "m2"])
        r.setEnabled("m1", true)
        #expect(r.pinnedTabs.map(\.id) == ["m0", "m1", "m2"])
        UserDefaults.standard.removeObject(forKey: "pinnedTabs")
        UserDefaults.standard.removeObject(forKey: "disabledModules")
    }
}
