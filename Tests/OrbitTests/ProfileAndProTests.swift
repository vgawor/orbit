import Foundation
import Testing
@testable import Orbit

@MainActor
struct ProfileAndProTests {
    @Test func botsNeverNameASpecificPerson() {
        let texts = [Bot.houseRules, Bot.chiefOfStaff.job, Bot.accountManager.job, BotGallery.blank().job]
            + BotGallery.templates.map(\.job)
            + OrbitTools.catalog.map(\.description)
        for text in texts {
            #expect(!text.contains("Viktor"), "found a name in: \(text.prefix(60))")
            #expect(!text.contains("Visualised"))
        }
        #expect(Bot.chiefOfStaff.job.contains("{{intro}}"))
        #expect(Bot.houseRules.contains("{{name}}"))
    }

    @Test func profileFillsIn() {
        let intro = UserProfile.intro(fullName: "Sam Lind", company: "Acme", about: "Sells bikes", country: "Sweden")
        #expect(intro == "Sam Lind works at Acme, in Sweden. Sells bikes.")
        #expect(UserProfile.intro(fullName: "Sam Lind", company: "", about: "", country: "Norway") == "Sam Lind is based in Norway.")
        #expect(UserProfile.intro(fullName: "Sam Lind", company: "", about: "", country: nil) == "Sam Lind.")
        let filled = UserProfile.fill("{{fullName}}'s bot. {{intro}} Ask {{name}} at {{company}}.",
                                      name: "Sam", fullName: "Sam Lind", company: "", intro: "Sam Lind.")
        #expect(filled == "Sam Lind's bot. Sam Lind. Ask Sam at their company.")
        // The agent sent to the cloud never contains a placeholder.
        let system = Bot.chiefOfStaff.agentConfig["system"] as? String ?? ""
        #expect(!system.contains("{{"))
    }

    @Test func proStaysOnOfflineForAWhile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Entitlements.recentlyPro(lastConfirmed: now.addingTimeInterval(-3 * 86400), now: now))
        #expect(!Entitlements.recentlyPro(lastConfirmed: now.addingTimeInterval(-15 * 86400), now: now))
        #expect(!Entitlements.recentlyPro(lastConfirmed: nil, now: now))
        // Test builds keep everything unlocked.
        if !Entitlements.proRequired && !Entitlements.shared.previewAsFree {
            #expect(Entitlements.shared.allows(.pro))
        }
        #expect(Entitlements.shared.allows(.free))
    }
}
