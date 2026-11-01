import Foundation
import Testing
@testable import Orbit

@Suite("Developer add-ons")
struct AddOnsDevelopersTests {
    // MARK: Ports

    @Test func parsesLsofFieldOutput() {
        let text = """
        p48211
        cnode
        f23
        n*:3000
        f24
        n127.0.0.1:9229
        f25
        n[::1]:3000
        p1834
        cpostgres
        f7
        n127.0.0.1:5432
        p99
        cnothing
        """
        let list = PortsParsing.parse(text)
        #expect(list.count == 2)
        #expect(list[0].name == "node" && list[0].pid == 48211)
        #expect(list[0].ports.map(\.port) == [3000, 9229])
        #expect(list[0].ports[0].address == "*")
        #expect(list[1].name == "postgres" && list[1].ports.map(\.port) == [5432])
    }

    @Test func parsesEndpoints() {
        #expect(PortsParsing.endpoint("[::1]:8080") == .init(port: 8080, address: "::1"))
        #expect(PortsParsing.endpoint("*:5173")?.port == 5173)
        #expect(PortsParsing.endpoint("garbage") == nil)
        #expect(PortsParsing.isLikelyHTTP(3000))
        #expect(!PortsParsing.isLikelyHTTP(5432))
    }

    // MARK: Docker

    @Test func parsesDockerJSONLines() {
        let text = """
        {"ID":"abc","Names":"db","Image":"postgres:16","State":"running","Status":"Up 3 hours","Ports":"0.0.0.0:5432->5432/tcp, :::5432->5432/tcp"}
        not json
        {"ID":"def","Names":"api","Image":"node:20","State":"exited","Status":"Exited (0) 2 days ago","Ports":""}
        {"ID":"ghi","Names":"cache","Image":"redis","Status":"Up 1 minute","Ports":"6379/tcp"}
        """
        let list = DockerParsing.containers(text)
        #expect(list.map(\.name) == ["cache", "db", "api"])
        #expect(list[1].ports == ["5432→5432"])
        #expect(list[0].isRunning && list[0].ports == ["6379"])
        #expect(!list[2].isRunning)
    }

    @Test func spotsDockerDaemonDown() {
        #expect(DockerParsing.isDaemonDown("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"))
        #expect(!DockerParsing.isDaemonDown("Error: No such container: x"))
        #expect(DockerParsing.firstLine("one\ntwo") == "one")
    }

    // MARK: GitHub Actions

    @Test func mapsRunStates() {
        #expect(ActionsParsing.state(status: "queued", conclusion: nil) == .queued)
        #expect(ActionsParsing.state(status: "in_progress", conclusion: nil) == .running)
        #expect(ActionsParsing.state(status: "completed", conclusion: "success") == .success)
        #expect(ActionsParsing.state(status: "completed", conclusion: "timed_out") == .failure)
        #expect(ActionsParsing.state(status: "completed", conclusion: "cancelled") == .cancelled)
    }

    @Test func parsesRunsJSON() {
        let json = """
        {"total_count":1,"workflow_runs":[{"id":42,"name":"CI","display_title":"Fix it","head_branch":"main",
        "status":"completed","conclusion":"failure","html_url":"https://github.com/o/r/actions/runs/42",
        "updated_at":"2026-10-28T09:12:44Z","created_at":"2026-10-28T09:00:00Z"}]}
        """
        let runs = ActionsParsing.runs(Data(json.utf8))
        #expect(runs.count == 1)
        #expect(runs[0].id == 42 && runs[0].state == .failure && runs[0].branch == "main" && runs[0].workflow == "CI")
        #expect(runs[0].updated == DevFormat.isoDate("2026-10-28T09:12:44Z"))
        #expect(ActionsParsing.defaultBranch(Data(#"{"default_branch":"trunk"}"#.utf8)) == "trunk")
        #expect(ActionsParsing.runs(Data("nope".utf8)).isEmpty)
    }

    @Test func normalizesRepos() {
        #expect(ActionsParsing.normalizeRepo(" apple/swift ") == "apple/swift")
        #expect(ActionsParsing.normalizeRepo("https://github.com/apple/swift.git") == "apple/swift")
        #expect(ActionsParsing.normalizeRepo("git@github.com:apple/swift.git") == "apple/swift")
        #expect(ActionsParsing.normalizeRepo("swift") == nil)
        #expect(ActionsParsing.normalizeRepo("a b/c") == nil)
    }

    @Test func formatsAges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DevFormat.age(now.addingTimeInterval(-30), now: now) == "now")
        #expect(DevFormat.age(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(DevFormat.age(now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(DevFormat.age(now.addingTimeInterval(-200_000), now: now) == "2d")
    }

    // MARK: Toolbox

    @Test func formatsJSONKeepingOrder() throws {
        let pretty = try DevTools.formatJSON(#"{"b":1,"a":[1, 2],"e":{},"s":"x, {y}: \"z\""}"#).get()
        #expect(pretty == """
        {
          "b": 1,
          "a": [
            1,
            2
          ],
          "e": {},
          "s": "x, {y}: \\"z\\""
        }
        """)
        let mini = try DevTools.formatJSON(pretty, indent: nil).get()
        #expect(mini == #"{"b":1,"a":[1,2],"e":{},"s":"x, {y}: \"z\""}"#)
    }

    @Test func reportsJSONErrorLine() {
        let issue = DevTools.jsonIssue("{\n  \"a\": 1,\n  \"b\": oops\n}")
        #expect(issue != nil)
        #expect(issue?.line == 3)
        #expect(DevTools.jsonIssue("[1, 2]") == nil)
    }

    @Test func base64AndURL() {
        #expect(DevTools.base64Encode("hello world") == "aGVsbG8gd29ybGQ=")
        #expect(DevTools.base64Decode("aGVsbG8gd29ybGQ") == "hello world")
        #expect(DevTools.base64Decode("!!!") == nil)
        #expect(DevTools.urlEncode("a b&c=ö/") == "a%20b%26c%3D%C3%B6%2F")
        #expect(DevTools.urlDecode("a%20b%26c") == "a b&c")
    }

    @Test func decodesJWT() throws {
        func part(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let token = part(#"{"alg":"HS256","typ":"JWT"}"#) + "." + part(#"{"sub":"42","exp":1700000000,"iat":1690000000}"#) + ".sig"
        let jwt = try #require(DevTools.decodeJWT("Bearer " + token))
        #expect(jwt.header.contains("\"alg\": \"HS256\""))
        #expect(jwt.expires == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(jwt.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(!jwt.isExpired(now: Date(timeIntervalSince1970: 1_600_000_000)))
        #expect(DevTools.decodeJWT("not a token") == nil)
    }

    @Test func makesUUIDs() {
        let id = DevTools.uuid()
        #expect(UUID(uuidString: id) != nil)
        #expect(Array(id)[14] == "4")
    }

    @Test func convertsTimestamps() throws {
        let utc = TimeZone(identifier: "UTC")!
        let seconds = try #require(DevTools.parseTime("1700000000", timeZone: utc))
        let ms = try #require(DevTools.parseTime("1700000000000", timeZone: utc))
        #expect(seconds == ms)
        #expect(DevTools.parseTime("2023-11-14T22:13:20Z") == seconds)
        #expect(DevTools.parseTime("2023-11-14 22:13:20", timeZone: utc) == seconds)
        #expect(DevTools.parseTime("hello") == nil)
        let rows = DevTools.timeRows(seconds, now: seconds.addingTimeInterval(3600), timeZone: utc)
        #expect(rows[0].1 == "1700000000")
        #expect(rows[1].1 == "1700000000000")
        #expect(rows[2].1 == "2023-11-14T22:13:20Z")
        #expect(rows.last?.1 == "1 h ago")
    }

    // MARK: Uptime

    @Test func uptimeMaths() {
        #expect(UptimeMath.uptimePercent([]) == nil)
        #expect(UptimeMath.uptimePercent([true, true, false, true]) == 75)
        #expect(UptimeMath.percentText(100) == "100%")
        #expect(UptimeMath.percentText(91.666) == "91.7%")
        #expect(UptimeMath.isUp(204) && UptimeMath.isUp(301) && !UptimeMath.isUp(500) && !UptimeMath.isUp(nil))
        #expect(UptimeMath.transition(previous: nil, now: false) == nil)
        #expect(UptimeMath.transition(previous: true, now: false) == .down)
        #expect(UptimeMath.transition(previous: false, now: true) == .recovered)
        #expect(UptimeMath.transition(previous: true, now: true) == nil)
    }

    @Test func normalizesSiteURLs() {
        #expect(UptimeMath.normalize("example.com") == "https://example.com")
        #expect(UptimeMath.normalize("http://localhost:3000/health") == "http://localhost:3000/health")
        #expect(UptimeMath.normalize("not a url") == nil)
        #expect(UptimeMath.normalize("nodot") == nil)
        #expect(UptimeMath.host("https://www.example.com/status") == "example.com/status")
    }
}

@Suite("Developer add-ons: Orbit and Home cards") @MainActor
struct DevelopersOrbitTests {
    private func run(_ state: ActionsRun.State, minutesAgo: Double, now: Date) -> ActionsRun {
        ActionsRun(id: 1, workflow: "CI", title: "", branch: "main", state: state, url: "https://github.com",
                   updated: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func freshPassesGetACelebration() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GitHubActionsAddOn.isFresh(run(.success, minutesAgo: 3, now: now), now: now))
        #expect(!GitHubActionsAddOn.isFresh(run(.success, minutesAgo: 20, now: now), now: now))
        #expect(!GitHubActionsAddOn.isFresh(run(.failure, minutesAgo: 1, now: now), now: now))
    }

    @Test func runStateWords() {
        #expect(ActionsWords.state(.running) == "running")
        #expect(ActionsWords.state(.success) == "passed")
        #expect(ActionsWords.state(.failure) == "failed")
    }

    @Test func everyDeveloperAddOnHasAHomeCard() {
        let ctx = AddOnContext(alerts: AlertCenter(), openPanel: { _ in }, closePanel: {})
        #expect(DeveloperAddOns.make(ctx).allSatisfy { $0.homeCard != nil })
    }
}
