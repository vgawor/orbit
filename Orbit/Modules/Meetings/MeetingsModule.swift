import AppKit
@preconcurrency import EventKit
import SwiftUI

/// Your next meeting from Calendar, with a countdown and one-click join (Zoom, Teams, Google Meet, Webex).
/// Pops an alert 2 minutes before a meeting starts.
@MainActor
@Observable
final class MeetingsModule: NotchModule {
    let id = "meetings"
    let title = "Meetings"
    let symbol = "calendar"

    enum Access { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var meetings: [Meeting] = []
    /// "Using Outlook? Add your account in Internet Accounts" (see CalendarHint).
    private(set) var hints: [CalendarHint] = []
    private let store = EKEventStore()
    private let alerts: AlertCenter
    private var timer: Timer?
    private var alerted: Set<String> = []
    private var changeObserver: NSObjectProtocol?

    /// Meetings you chose to keep out of the peek, alerts and Home card (still listed here).
    private(set) var hiddenIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "meetings.hiddenFromPeek") ?? [])

    func setHidden(_ m: Meeting, _ hidden: Bool) {
        if hidden { hiddenIDs.insert(m.id) } else { hiddenIDs.remove(m.id) }
        // Old ones fall off; event ids include the start time, so they never come back.
        UserDefaults.standard.set(Array(hiddenIDs.suffix(300)), forKey: "meetings.hiddenFromPeek")
    }

    /// In the peek, alerts and Home card: not hidden, and not a long block (trips, all-week events).
    func showsInPeek(_ m: Meeting) -> Bool { !hiddenIDs.contains(m.id) && !m.isLong }

    /// How long before the start the "starts soon" alert appears.
    static let alertLead: TimeInterval = 120

    init(alerts: AlertCenter) {
        self.alerts = alerts
    }

    /// The next meeting that shows in the peek.
    var next: Meeting? { meetings.first { $0.end > .now && showsInPeek($0) } }

    // MARK: Lifecycle

    func start() {
        // On first launch, onboarding asks for calendar access in its Connect step.
        if Onboarding.isDone || EKEventStore.authorizationStatus(for: .event) == .fullAccess { requestAccess() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.checkAlerts()
            }
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            access = .granted
            reload()
            return
        }
        if status == .denied || status == .restricted {
            access = .denied
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.access = granted ? .granted : .denied
                self?.reload()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Layout snapshots only.
    func previewHints() { hints = [CalendarHint(kind: .outlook)] }

    func dismissHint(_ hint: CalendarHint) {
        CalendarHint.dismiss(hint.kind)
        hints.removeAll { $0 == hint }
    }

    func openInternetAccounts() { Onboarding.openInternetAccounts() }

    private func updateHints() {
        hints = CalendarHint.hints(sources: CalendarHint.sources(in: store), outlookInstalled: CalendarHint.outlookInstalled,
                                   googleAppInstalled: CalendarHint.googleAppInstalled, dismissed: CalendarHint.dismissed)
    }

    private func reload() {
        guard access == .granted else { return }
        updateHints()
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600),
                                                 end: now.addingTimeInterval(36 * 3600), calendars: nil)
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map(Meeting.init)
        checkAlerts()
    }

    private func checkAlerts() {
        guard let m = meetings.first(where: { $0.start > .now.addingTimeInterval(-60) && showsInPeek($0) }) else { return }
        let until = m.start.timeIntervalSinceNow
        guard until <= Self.alertLead, !alerted.contains(m.id) else { return }
        alerted.insert(m.id)
        let minutes = max(0, Int((until / 60).rounded(.up)))
        var actions: [NotchAlert.Action] = [.init(title: "Later")]
        if let link = m.link {
            actions.append(.init(title: "Join \(link.provider.rawValue)", isPrimary: true, tint: link.provider.tint) { [weak self] in self?.join(m) })
        }
        alerts.post(NotchAlert(
            symbol: "video.fill", tint: m.tint,
            title: minutes > 0 ? "\(m.title) starts in \(minutes) min" : "\(m.title) is starting",
            subtitle: m.subtitle, actions: actions, duration: 20, sound: "Glass"
        ))
    }

    /// For troubleshooting: where the next meetings' links are, with surrounding text trimmed.
    func debugLinks() -> [[String: String]] {
        guard access == .granted else { return [["error": "no calendar access"]] }
        let predicate = store.predicateForEvents(withStart: .now.addingTimeInterval(-3600),
                                                 end: .now.addingTimeInterval(24 * 3600), calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.prefix(4).map { e in
            func links(_ s: String?) -> String {
                guard let s else { return "-" }
                let found = s.components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.lowercased().contains("zoom") || $0.lowercased().contains("http") || $0.lowercased().contains("teams") || $0.lowercased().contains("meet.google") }
                return found.isEmpty ? "(no links, \(s.count) chars)" : found.prefix(5).joined(separator: " ")
            }
            return ["title": e.title ?? "", "start": e.startDate.formatted(),
                    "calendar": e.calendar?.title ?? "", "url": e.url?.absoluteString ?? "-",
                    "location": links(e.location), "notes": links(e.notes),
                    "detected": MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]).map { "\($0.provider.rawValue): \($0.url.absoluteString.prefix(60))…" } ?? "none"]
        }
    }

    func join(_ meeting: Meeting) {
        guard let link = meeting.link else { return }
        let web = link.url
        // Open straight in the meeting app when it's installed; otherwise the browser.
        if let app = link.appURL,
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(web)
        }
    }

    // MARK: Views

    /// A meeting with a video link that's on now or starts within 10 minutes: time to join.
    var joinable: Meeting? {
        guard let m = next, m.link != nil, m.start.timeIntervalSinceNow < 600 else { return nil }
        return m
    }

    var peekView: AnyView? {
        // On now or starting soon: a Join button instead of the countdown.
        if let m = joinable, let link = m.link {
            return AnyView(Button { self.join(m) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill").font(.system(size: 10, weight: .semibold))
                    Text("Join").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(link.provider.tint))
                .foregroundStyle(.white)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Join \(m.title) in \(link.provider.rawValue)"))
        }
        guard let m = next, m.start.timeIntervalSinceNow < 3600 else { return nil }
        return AnyView(TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 6) {
                Circle().fill(m.tint).frame(width: 8, height: 8)
                // Before it starts: time until it starts. While it runs: time left (the chip below names it).
                Text(m.isNow ? Meeting.countdown(to: m.end) + " left" : Meeting.countdown(to: m.start))
            }
        })
    }
    /// Joining beats other glances (focus timer, agents) while it's time to join.
    var peekPriority: Int { joinable != nil ? 4 : 1 }

    var peekChip: PeekChip? {
        guard let m = next, m.start.timeIntervalSinceNow < 8 * 3600 else { return nil }
        let when = m.isNow ? "Now" : "In " + Meeting.countdown(to: m.start)
        let name = m.title.trimmingCharacters(in: .whitespaces)
        return PeekChip(symbol: m.link == nil ? "calendar" : "video.fill", text: "\(when) · \(name)",
                        tint: m.link == nil ? Tokens.secondary : m.tint,
                        priority: m.start.timeIntervalSinceNow < 900 ? 4 : 3)
    }

    var attention: Attention? {
        guard let m = next else { return nil }
        let until = m.start.timeIntervalSinceNow
        guard until <= 300, until > -300 else { return nil }
        let mins = Int((until / 60).rounded(.up))
        return Attention(id: "meeting-\(m.id)", symbol: "video.fill", tint: m.tint,
                         label: mins > 0 ? "\(mins)m" : "Now", priority: 3,
                         headline: mins > 0 ? "Meeting in \(mins) min" : "Meeting now")
    }

    var homeCard: AnyView? { AnyView(NextMeetingCard(module: self)) }
    var panel: AnyView { AnyView(AgendaView(module: self)) }
}

// MARK: - Model

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let people: Int
    let link: MeetingLink?
    /// Email addresses of the other people invited (not you).
    let attendeeEmails: [String]
    let calendarColor: Color

    init(_ e: EKEvent) {
        id = (e.calendarItemIdentifier) + "\(e.startDate.timeIntervalSince1970)"
        title = e.title?.isEmpty == false ? e.title! : "Untitled"
        start = e.startDate
        end = e.endDate
        people = e.attendees?.count ?? 0
        link = MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes])
        attendeeEmails = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p in
            let s = p.url.absoluteString
            return s.lowercased().hasPrefix("mailto:") ? String(s.dropFirst(7)).removingPercentEncoding : nil
        }
        calendarColor = e.calendar.map { Color(nsColor: $0.color) } ?? .gray
    }

    var isNow: Bool { start <= .now && end > .now }

    /// Longer than this, an event is a block of time (a trip, a conference) rather than a meeting:
    /// it's listed, but never counted down in the peek.
    nonisolated static let longEvent: TimeInterval = 8 * 3600
    var isLong: Bool { end.timeIntervalSince(start) > Self.longEvent }

    /// "in 2 h 15 min", "now · 35 min left", "ended".
    func relative(now: Date = .now) -> String {
        if end <= now { return "ended" }
        if start <= now { return "now · \(Self.span(end.timeIntervalSince(now))) left" }
        let until = start.timeIntervalSince(now)
        return until < 60 ? "starting" : "in \(Self.span(until))"
    }

    /// "35 min", "2 h 15 min", "1 d 3 h".
    static func span(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded(.up)))
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60, rest = mins % 60
        if hours < 24 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
        let days = hours / 24, h = hours % 24
        return h == 0 ? "\(days) d" : "\(days) d \(h) h"
    }

    /// The meeting app's colour, or Zoom blue for meetings without a link.
    var tint: Color { link?.provider.tint ?? Tokens.zoom }

    var timeRange: String {
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(f))–\(end.formatted(f))"
    }

    var subtitle: String {
        var parts = [timeRange]
        if people > 0 { parts.append("\(people) people") }
        if let link { parts.append(link.provider.rawValue) }
        return parts.joined(separator: " · ")
    }

    static func countdown(to date: Date) -> String {
        let mins = Int((date.timeIntervalSinceNow / 60).rounded(.up))
        if mins < 60 { return "\(max(mins, 0))m" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}

/// A video-call link found in a calendar event.
struct MeetingLink: Equatable {
    enum Provider: String {
        case zoom = "Zoom", teams = "Teams", meet = "Meet", webex = "Webex"

        var tint: Color {
            switch self {
            case .zoom: Tokens.zoom
            case .teams: Color(red: 0.36, green: 0.37, blue: 0.85)   // #5B5FD9
            case .meet: Color(red: 0.0, green: 0.62, blue: 0.47)     // #009E78
            case .webex: Color(red: 0.0, green: 0.6, blue: 0.85)
            }
        }
    }

    let provider: Provider
    let url: URL

    /// Opens in the desktop app instead of the browser, where that's possible.
    var appURL: URL? {
        switch provider {
        case .zoom:
            return ZoomLink.appURL(from: url)
        case .teams:
            // Only full "meetup-join" links work with the Teams app scheme.
            let s = url.absoluteString
            guard s.contains("/l/meetup-join/") else { return nil }
            return URL(string: s.replacingOccurrences(of: "https://teams.microsoft.com", with: "msteams:"))
        case .meet, .webex:
            return nil
        }
    }

    // Checked in this order; the first match in any text wins.
    private static let patterns: [(Provider, NSRegularExpression)] = ([
        (Provider.zoom, #"https://([a-z0-9-]+\.)?zoom\.us/(j|my|w)/[^\s<>"')]+"#),
        (.teams, #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#),
        (.teams, #"https://teams\.microsoft\.com/meet/[^\s<>"')]+"#),
        (.teams, #"https://teams\.live\.com/meet/[^\s<>"')]+"#),
        (.meet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"')]*"#),
        (.webex, #"https://([a-z0-9-]+\.)?webex\.com/(meet|join|[a-z0-9-]+/j\.php)[^\s<>"')]*"#),
    ] as [(Provider, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    static func find(in texts: [String?]) -> MeetingLink? {
        let texts = texts.compactMap { $0 }
        for (provider, regex) in patterns {
            for text in texts {
                let range = NSRange(text.startIndex..., in: text)
                if let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text),
                   let url = URL(string: String(text[r])) {
                    return MeetingLink(provider: provider, url: url)
                }
            }
        }
        return nil
    }
}

/// Turns Zoom web links into links the Zoom app opens directly.
enum ZoomLink {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https://([a-z0-9-]+\.)?zoom\.us/(j|my|w)/[^\s<>"')]+"#, options: [.caseInsensitive])

    static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = pattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }

    /// `https://x.zoom.us/j/123?pwd=abc` → `zoommtg://x.zoom.us/join?confno=123&pwd=abc`
    static func appURL(from web: URL) -> URL? {
        let parts = web.pathComponents
        guard let i = parts.firstIndex(of: "j"), i + 1 < parts.count else { return nil }
        var c = URLComponents()
        c.scheme = "zoommtg"
        c.host = web.host
        c.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: parts[i + 1])]
        if let pwd = URLComponents(url: web, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        c.queryItems = items
        return c.url
    }
}

// MARK: - Views

struct NextMeetingCard: View {
    let module: MeetingsModule

    var body: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Next meeting")
                switch module.access {
                case .granted:
                    if let m = module.next {
                        Text(m.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(m.subtitle).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tokens.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            countdown(m)
                        }
                        HStack {
                            if let link = m.link {
                                Label(link.provider.rawValue, systemImage: "circle.fill").labelStyle(DotLabel(color: link.provider.tint))
                                Spacer()
                                PillButton(title: "Join", fill: link.provider.tint) { module.join(m) }
                            }
                        }
                    } else {
                        Spacer(minLength: 0)
                        if let hint = module.hints.first {
                            Text(hint.title).font(.system(size: 13, weight: .medium))
                            Text("Add the account in Internet Accounts to see those meetings.")
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(2)
                            PillButton(title: "Open Internet Accounts", fill: Tokens.surface2) { module.openInternetAccounts() }
                        } else {
                            Text("Nothing else today").font(.system(size: 13, weight: .medium))
                            Text("Enjoy the quiet.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                        }
                    }
                case .denied:
                    Spacer(minLength: 0)
                    Text("Calendar access is off").font(.system(size: 13, weight: .medium))
                    PillButton(title: "Open Settings", fill: Tokens.surface2) { module.openPrivacySettings() }
                case .unknown:
                    Spacer(minLength: 0)
                    PillButton(title: "Show my meetings", fill: Tokens.surface2) { module.requestAccess() }
                }
            }
        }
    }

    @ViewBuilder private func countdown(_ m: Meeting) -> some View {
        if m.isNow {
            Text("Now").font(.system(size: 24, weight: .semibold)).foregroundStyle(Tokens.live)
        } else {
            let mins = Int((m.start.timeIntervalSinceNow / 60).rounded(.up))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(mins < 60 ? "\(mins)" : m.start.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                if mins < 60 { Text("min").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.secondary) }
            }
        }
    }
}

struct AgendaView: View {
    let module: MeetingsModule

    var body: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel("Coming up")
                ForEach(module.hints) { hint in CalendarHintRow(hint: hint, module: module) }
                if module.meetings.isEmpty {
                    Text(module.access == .granted ? "No more meetings in the next 36 hours." : "Allow calendar access from the Home card.")
                        .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(module.meetings) { m in
                            MeetingRow(meeting: m, module: module, dayLabel: dayLabel(m))
                        }
                    }
                }
            }
        }
    }

    private func dayLabel(_ m: Meeting) -> String {
        Calendar.current.isDateInToday(m.start) ? "" : "Tomorrow · "
    }
}

/// One meeting in the list: when it is relative to now, Join, and Hide from peek (eye, or right-click).
struct MeetingRow: View {
    let meeting: Meeting
    let module: MeetingsModule
    let dayLabel: String
    @State private var hovering = false

    var body: some View {
        let m = meeting
        let hidden = !module.showsInPeek(m)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(m.calendarColor).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(m.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if hidden {
                        Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(Tokens.faint)
                            .help(m.isLong ? "Long events don't show in the peek" : "Hidden from the peek")
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 0) {
                        Text(m.relative(now: context.date))
                            .foregroundStyle(m.isNow ? Tokens.live : m.start.timeIntervalSince(context.date) < 900 ? Tokens.attention : Tokens.secondary)
                        Text(" · " + dayLabel + m.subtitle).foregroundStyle(Tokens.secondary)
                    }
                    .font(.system(size: 11.5).monospacedDigit()).lineLimit(1)
                }
            }
            Spacer()
            if (hovering || hiddenByYou) && !m.isLong {
                Button { module.setHidden(m, !hiddenByYou) } label: {
                    Image(systemName: hiddenByYou ? "eye.slash.fill" : "eye").font(.system(size: 12))
                        .foregroundStyle(hiddenByYou ? Tokens.secondary : Tokens.faint)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hiddenByYou ? "Show in the peek again" : "Don't show this meeting in the peek")
            }
            if let link = m.link {
                PillButton(title: "Join", fill: m.start.timeIntervalSinceNow < 900 ? link.provider.tint : Tokens.surface2) {
                    module.join(m)
                }
            }
        }
        .padding(8)
        .opacity(hidden && !m.isNow ? 0.6 : 1)
        .background(m.isNow ? Tokens.surface2 : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if m.isLong {
                Text("Long events don't show in the peek")
            } else {
                Button(hiddenByYou ? "Show in the peek" : "Hide from the peek") { module.setHidden(m, !hiddenByYou) }
            }
            if let link = m.link { Button("Join in \(link.provider.rawValue)") { module.join(m) } }
        }
    }

    private var hiddenByYou: Bool { module.hiddenIDs.contains(meeting.id) }
}

struct PillButton: View {
    let title: String
    var fill: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .foregroundStyle(fill == .white ? Color.black : Color.white)
                .background {
                    // The main action is a white pill; grey (surface) fills become glass.
                    if fill == Tokens.surface || fill == Tokens.surface2 { Color.clear.glassSurface(Capsule(), interactive: true) }
                    else { Capsule().fill(fill) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DotLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            configuration.title.font(.system(size: 11)).foregroundStyle(Tokens.secondary)
        }
    }
}


/// The Outlook / Google hint in the agenda, with Orbit, a button and a close ×.
struct CalendarHintRow: View {
    let hint: CalendarHint
    let module: MeetingsModule

    var body: some View {
        HStack(spacing: 10) {
            OrbitView(size: 30, mood: .wide, motion: .glow, tint: hint.kind == .outlook ? Tokens.zoom : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(hint.title).font(.system(size: 12.5, weight: .semibold))
                Text(hint.detail).font(.system(size: 11)).foregroundStyle(Tokens.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            PillButton(title: "Open Internet Accounts", fill: Tokens.surface2) { module.openInternetAccounts() }
            Button { module.dismissHint(hint) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(Tokens.surface2))
            }
            .buttonStyle(.plain).help("Don't show this again")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
