import AppKit
import EventKit

/// "Using Outlook? Add your work account in Internet Accounts."
///
/// Orbit reads meetings from the calendars macOS knows about. The new Outlook for Mac and Google
/// Calendar in a browser keep their calendars to themselves, so if Orbit sees signs of either
/// (the Outlook app, or a Google app such as the Google Calendar web app or Google Drive) but
/// no matching calendar account, Meetings suggests adding it in System Settings → Internet Accounts.
/// Nothing is read from browsers or other apps; only which apps are installed.
struct CalendarHint: Identifiable, Equatable {
    enum Kind: String { case outlook, google }

    let kind: Kind
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .outlook: "Using Outlook?"
        case .google: "Using Google Calendar?"
        }
    }

    var detail: String {
        switch kind {
        case .outlook: "Add your work account in Internet Accounts so your Outlook meetings show here."
        case .google: "Add your Google account in Internet Accounts so your Google meetings show here."
        }
    }

    /// A calendar account macOS knows about (from EventKit).
    struct Source: Equatable {
        let title: String
        let isExchange: Bool
    }

    /// Which hints to show. Pure, so it's easy to test.
    static func hints(sources: [Source], outlookInstalled: Bool, googleAppInstalled: Bool, dismissed: Set<String>) -> [CalendarHint] {
        func has(_ words: [String]) -> Bool {
            sources.contains { s in words.contains { s.title.localizedCaseInsensitiveContains($0) } }
        }
        let hasMicrosoft = sources.contains(where: \.isExchange) || has(["outlook", "exchange", "microsoft", "office", "hotmail", "live.com"])
        let hasGoogle = has(["google", "gmail"])
        var out: [CalendarHint] = []
        if outlookInstalled && !hasMicrosoft && !dismissed.contains(Kind.outlook.rawValue) { out.append(.init(kind: .outlook)) }
        if googleAppInstalled && !hasGoogle && !dismissed.contains(Kind.google.rawValue) { out.append(.init(kind: .google)) }
        return out
    }

    static func sources(in store: EKEventStore) -> [Source] {
        store.sources.map { Source(title: $0.title, isExchange: $0.sourceType == .exchange) }
    }

    static var outlookInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil
    }

    /// Google Calendar saved as a web app (Chrome or Safari), or Google Drive for desktop.
    static var googleAppInstalled: Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Applications/Chrome Apps.localized/Google Calendar.app",
            "\(home)/Applications/Google Calendar.app",
            "/Applications/Google Calendar.app",
        ]
        if candidates.contains(where: fm.fileExists(atPath:)) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.drivefs") != nil
    }

    static let dismissedKey = "meetings.hints.dismissed"

    static var dismissed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    static func dismiss(_ kind: Kind) {
        UserDefaults.standard.set(Array(dismissed.union([kind.rawValue])), forKey: dismissedKey)
    }
}
