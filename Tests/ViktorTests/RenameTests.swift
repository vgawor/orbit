import Foundation
import Testing
@testable import Viktor

struct RenameTests {
    @Test func settingsFromTheOldIdentityAreCopiedOnce() {
        let name = "rename-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["tasks"], forKey: "pinnedTabs")
        LegacySettings.migrate(into: defaults, old: [
            ["pinnedTabs": ["music"], "enabledAddOns": ["addon.water"]],   // newest old id
            ["enabledAddOns": ["addon.arcade"], "look.color": "mint"],       // oldest
        ])
        // Keeps what's already set, fills in the rest.
        #expect(defaults.stringArray(forKey: "pinnedTabs") == ["tasks"])
        #expect(defaults.stringArray(forKey: "enabledAddOns") == ["addon.water"])   // newer id wins
        #expect(defaults.string(forKey: "look.color") == "mint")
        // Only once.
        LegacySettings.migrate(into: defaults, old: [["look.name": "X"]])
        #expect(defaults.string(forKey: "look.name") == nil)
    }
}
