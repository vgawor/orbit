import Foundation
import Testing
@testable import Orbit

@Suite("Meeting links")
@MainActor struct MeetingLinkTests {
    @Test func findsZoomAndBuildsAppLink() throws {
        let link = try #require(MeetingLink.find(in: [nil, "Join: https://us02web.zoom.us/j/84512345678?pwd=AbC123.1 now"]))
        #expect(link.provider == .zoom)
        #expect(link.appURL?.absoluteString == "zoommtg://us02web.zoom.us/join?action=join&confno=84512345678&pwd=AbC123.1")
    }

    @Test func prefersTeamsMeetupJoinOverShortLink() throws {
        let notes = "Teams-möte https://teams.microsoft.com/meet/3346411124431050?p=1M0V <https://aka.ms/JoinTeamsMeeting> <https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=x>"
        let link = try #require(MeetingLink.find(in: [notes]))
        #expect(link.provider == .teams)
        #expect(link.url.absoluteString.contains("/l/meetup-join/"))
        #expect(link.appURL?.scheme == "msteams")
    }

    @Test func teamsShortLinkOpensInBrowser() throws {
        let link = try #require(MeetingLink.find(in: ["https://teams.microsoft.com/meet/123?p=abc"]))
        #expect(link.provider == .teams)
        #expect(link.appURL == nil)
    }

    @Test func findsGoogleMeetAndWebex() {
        #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.provider == .meet)
        #expect(MeetingLink.find(in: ["https://acme.webex.com/meet/sam"])?.provider == .webex)
    }

    @Test func ignoresTextWithoutLinks() {
        #expect(MeetingLink.find(in: ["Room 3", nil, "https://example.com"]) == nil)
    }

    @Test func countdownText() {
        #expect(Meeting.countdown(to: .now.addingTimeInterval(5 * 60)) == "5m")
        #expect(Meeting.countdown(to: .now.addingTimeInterval(125 * 60)) == "2h 5m")
        #expect(Meeting.countdown(to: .now.addingTimeInterval(-60)) == "0m")
    }
}

@Suite("Task text and dates")
@MainActor struct TaskParsingTests {
    @Test func plainTitleHasNoDate() {
        let r = TaskParser.parse("Buy milk")
        #expect(r.title == "Buy milk")
        #expect(r.due == nil)
    }

    @Test func tomorrowWithTime() throws {
        let r = TaskParser.parse("Send offer tomorrow at 14:00")
        #expect(r.title == "Send offer")
        let due = try #require(r.due)
        #expect(r.hasTime)
        #expect(Calendar.current.isDateInTomorrow(due))
        #expect(Calendar.current.component(.hour, from: due) == 14)
    }

    @Test func dayOnlyIsStartOfDay() throws {
        let r = TaskParser.parse("Call Anna tomorrow")
        let due = try #require(r.due)
        #expect(!r.hasTime)
        #expect(due == Calendar.current.startOfDay(for: due))
    }

    @Test func overdueAndToday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        #expect(TaskItem(title: "a", due: Calendar.current.startOfDay(for: yesterday)).isOverdue)
        #expect(!TaskItem(title: "b", due: .now.addingTimeInterval(3600), dueHasTime: true).isOverdue)
        #expect(TaskItem(title: "c", due: .now.addingTimeInterval(-60), dueHasTime: true).isOverdue)
        #expect(!TaskItem(title: "d", done: true, due: yesterday).isOverdue)
        #expect(TaskItem(title: "e", due: Calendar.current.startOfDay(for: .now)).isDueToday)
    }
}

@Suite("Smart Ask dates")
@MainActor struct SmartDateTests {
    @Test(arguments: [
        ("2026-10-30", false, 0),
        ("2026-10-30T08:00", true, 8),
        ("2026-10-30T08:00:00", true, 8),
        ("2026-11-02 09:30", true, 9),
    ])
    @MainActor func parses(_ text: String, _ hasTime: Bool, _ hour: Int) throws {
        let (date, t) = SmartAssistant.parseDate(text)
        let d = try #require(date)
        #expect(t == hasTime)
        #expect(Calendar.current.component(.hour, from: d) == hour)
    }

    @Test @MainActor func rejectsNonsense() {
        #expect(SmartAssistant.parseDate("next blue moon").0 == nil)
        #expect(SmartAssistant.parseDate(nil).0 == nil)
    }
}

@Suite("Other parsers")
@MainActor struct OtherParserTests {
    @Test func spotifyLinks() throws {
        let a = try #require(FocusPlaylist.parse("https://open.spotify.com/playlist/37i9dQZF1DWZeKCadgRdKQ?si=abc"))
        #expect(a.uri == "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ")
        let b = try #require(FocusPlaylist.parse("https://open.spotify.com/intl-sv/album/1ATL5GLyefJaxhQzSPVrLX"))
        #expect(b.uri == "spotify:album:1ATL5GLyefJaxhQzSPVrLX")
        #expect(FocusPlaylist.parse("spotify:playlist:xyz")?.uri == "spotify:playlist:xyz")
        #expect(FocusPlaylist.parse("https://example.com/playlist/1") == nil)
        #expect(FocusPlaylist.parse("hello") == nil)
    }

    @Test func youTubeLinks() {
        #expect(YouTubeLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90")?.start == 90)
        #expect(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=1m30s")?.start == 90)
        #expect(YouTubeLink.parse("youtube.com/shorts/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("Great talk https://www.youtube.com/embed/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("https://vimeo.com/123") == nil)
        #expect(YouTubeLink.parse("https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
    }

    @Test func sshCommandLines() throws {
        let a = try #require(SSHModule.parse(pid: 1, etime: "12:34", args: "-L 5432:db:5432 -i ~/.ssh/key deploy@prod.example.com".split(separator: " ").map(String.init)))
        #expect(a.host == "prod.example.com")
        #expect(a.tunnels == ["L 5432:db:5432"])
        #expect(a.elapsed == "12m")
        let b = try #require(SSHModule.parse(pid: 2, etime: "02:05:10", args: ["-p", "2222", "-D1080", "user@10.0.0.4", "uptime"]))
        #expect(b.host == "10.0.0.4")
        #expect(b.tunnels == ["D 1080"])
        #expect(b.elapsed == "2h 05m")
        #expect(SSHModule.humanElapsed("3-04:00:00") == "3d 4h")
        #expect(SSHModule.parse(pid: 3, etime: "00:01", args: ["-v"]) == nil)
    }

    @Test func timerPhrases() {
        #expect(AskModule.timerMinutes("timer 10 min") == 10)
        #expect(AskModule.timerMinutes("10 min timer") == 10)
        #expect(AskModule.timerMinutes("focus 25") == 25)
        #expect(AskModule.timerMinutes("1 hour timer") == 60)
        #expect(AskModule.timerMinutes("15m") == 15)
        #expect(AskModule.timerMinutes("call anna about the 3 offers") == nil)
    }
}
