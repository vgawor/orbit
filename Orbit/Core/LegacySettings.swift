import Foundation

/// Settings saved under Orbit's earlier app ids are copied over once, so add-ons, pinned tabs,
/// snoozes and the rest survive the change. Newest id first: its values win.
enum LegacySettings {
    static let oldDomains = ["se.visualised.orbit", "se.visualised.viktor"]
    static let doneKey = "migratedFromOldIDs"

    static func migrate(into defaults: UserDefaults = .standard,
                        old: [[String: Any]]? = nil) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        let sources = old ?? oldDomains.compactMap { UserDefaults.standard.persistentDomain(forName: $0) }
        for domain in sources {
            for (key, value) in domain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
