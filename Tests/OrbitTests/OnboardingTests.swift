import Foundation
import Testing
@testable import Orbit

@MainActor
struct OnboardingTests {
    @Test func everyRoleStartsWithRealAddOns() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        let ids = Set(AddOnCatalog.make(ctx).map(\.id))
        for role in Onboarding.Role.allCases {
            #expect(!role.addOns.isEmpty, "\(role)")
            for id in role.addOns { #expect(ids.contains(id), "\(role): \(id)") }
        }
    }

    @Test func visitsAreRemembered() {
        let tab = "test-\(UUID().uuidString)"
        #expect(!Onboarding.hasVisited(tab))
        Onboarding.visited(tab)
        #expect(Onboarding.hasVisited(tab))
        UserDefaults.standard.removeObject(forKey: "gs.visited.\(tab)")
    }

    @Test func developmentBuildsAreNotMoved() {
        // Tests run from .build, which never counts as "needs moving".
        #expect(!AppMover.needsMove)
    }
}
