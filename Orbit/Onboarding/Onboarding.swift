import AppKit
import SwiftUI

/// First-run state: whether onboarding is done, the starter add-ons for each role, and the
/// "Get started" checklist on Home.
@MainActor
enum Onboarding {
    static let doneKey = "onboarding.done"

    /// True once onboarding finished or was skipped (or for people who used Orbit before it existed).
    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// Music asks macOS to control Spotify and Music, which shows a permission prompt. Until
    /// onboarding reaches that step, Music waits, so the first launch doesn't open with prompts.
    static var allowsMusicPrompt: Bool {
        isDone || UserDefaults.standard.bool(forKey: "onboarding.music")
    }

    static func allowMusic() { UserDefaults.standard.set(true, forKey: "onboarding.music") }

    /// People who used Orbit (or Viktor, its old name) before onboarding existed skip it.
    static func markDoneIfReturningUser() {
        guard !isDone else { return }
        let d = UserDefaults.standard
        let usedBefore = d.object(forKey: "look.companion") != nil || d.object(forKey: "disabledModules") != nil
            || d.object(forKey: "enabledAddOns") != nil
            || FileManager.default.fileExists(atPath: Storage.folder.appendingPathComponent("notes.json").path)
        if usedBefore { isDone = true }
    }

    // MARK: Roles

    enum Role: String, CaseIterable, Identifiable {
        case developer, sales, student, creative, personal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .developer: "Developer"
            case .sales: "Sales & customers"
            case .student: "Student"
            case .creative: "Creative"
            case .personal: "Just me"
            }
        }

        var symbol: String {
            switch self {
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .sales: "person.2.fill"
            case .student: "graduationcap.fill"
            case .creative: "paintbrush.pointed.fill"
            case .personal: "house.fill"
            }
        }

        /// Starter add-ons. You can add or remove any of them later in Settings → Add-ons.
        var addOns: [String] {
            switch self {
            case .developer: ["addon.ports", "addon.docker", "addon.devtools", "addon.ghactions", "addon.clipboard", "addon.weather"]
            case .sales: ["addon.daytimeline", "addon.worldclock", "addon.countdowns", "addon.snippets", "addon.actionitems", "addon.weather"]
            case .student: ["addon.breaks", "addon.water", "addon.breathe", "addon.countdowns", "addon.funfact", "addon.arcade"]
            case .creative: ["addon.clipboard", "addon.mood", "addon.breathe", "addon.weather", "addon.onthisday", "addon.decide"]
            case .personal: ["addon.weather", "addon.water", "addon.funfact", "addon.countdowns"]
            }
        }
    }

    static func apply(_ role: Role, to registry: ModuleRegistry) {
        let known = Set(registry.addOns.map(\.id))
        for id in role.addOns where known.contains(id) { registry.setEnabled(id, true) }
        UserDefaults.standard.set(role.rawValue, forKey: "onboarding.role")
    }

    // MARK: Get started checklist

    /// Tabs you've opened, for the checklist (recorded by the notch).
    static func visited(_ tab: String) {
        let key = "gs.visited.\(tab)"
        if !UserDefaults.standard.bool(forKey: key) { UserDefaults.standard.set(true, forKey: key) }
    }
    static func hasVisited(_ tab: String) -> Bool { UserDefaults.standard.bool(forKey: "gs.visited.\(tab)") }

    static let checklistHiddenKey = "gs.hidden"

    // MARK: Music permission

    /// Asks macOS for permission to control Spotify and Music (whichever is running).
    /// Returns false when neither is open, so there was nothing to ask about yet.
    static func requestMusicPermission() async -> Bool {
        allowMusic()
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let players = ["com.spotify.client", "com.apple.Music"].filter(running.contains)
        guard !players.isEmpty else { return false }
        await Task.detached {
            for id in players {
                let target = NSAppleEventDescriptor(bundleIdentifier: id)
                _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            }
        }.value
        return true
    }

    static var outlookInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil
    }

    static func openInternetAccounts() {
        let urls = ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                    "x-apple.systempreferences:com.apple.preferences.internetaccounts"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
