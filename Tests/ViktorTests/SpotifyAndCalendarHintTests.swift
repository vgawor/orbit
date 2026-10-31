import Foundation
import Testing
@testable import Viktor

@MainActor
struct SpotifyConnectTests {
    @Test func pkceChallengeMatchesTheStandardExample() {
        // RFC 7636, appendix B.
        #expect(SpotifyConnect.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = SpotifyConnect.randomString(64)
        #expect(v.count == 64)
        #expect(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func authorizeURLAsksOnlyForPlaybackAccess() throws {
        let url = try #require(SpotifyConnect.authorizeURL(clientID: "abc", challenge: "xyz", state: "s1"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.spotify.com")
        #expect(items["client_id"] == "abc")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://127.0.0.1:47900/spotify/callback")
        #expect(items["scope"] == "user-read-playback-state user-modify-playback-state")
        #expect(items["state"] == "s1")
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(SpotifyConnect.formEncode(["b": "a b&c", "a": "http://x/y"]) == "a=http%3A%2F%2Fx%2Fy&b=a%20b%26c")
    }

    @Test func devicesDecodeWithSymbols() throws {
        let json = #"{"devices":[{"id":"1","name":"Sam's MacBook","type":"Computer","is_active":true,"is_restricted":false,"volume_percent":60},{"id":"2","name":"Kitchen","type":"Speaker","is_active":false,"is_restricted":false,"volume_percent":null},{"id":null,"name":"Ghost","type":"TV","is_active":false,"is_restricted":true}]}"#
        struct List: Decodable { let devices: [SpotifyConnect.Device] }
        let list = try JSONDecoder().decode(List.self, from: Data(json.utf8)).devices
        #expect(list.count == 3)
        #expect(list[0].isActive && list[0].symbol == "laptopcomputer")
        #expect(list[1].symbol == "hifispeaker.fill" && list[1].volume == nil)
        #expect(list[2].id.isEmpty)   // devices without an id are hidden by loadDevices
    }

    @Test func aCallbackWithoutAPendingSignInIsRefused() async {
        let page = await SpotifyConnect().handleCallback(query: ["code": "x", "state": "forged"])
        #expect(page.contains("expired"))
    }

    @Test func errorsReadClearly() {
        #expect(SpotifyConnect.describe(SpotifyConnect.APIError.status(403, "x")).contains("Premium"))
    }
}

struct LocalServerQueryTests {
    @Test func queryStringIsParsed() throws {
        let raw = "GET /spotify/callback?code=a%20b&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let req = try #require(HTTPRequest.parse(Data(raw.utf8)))
        #expect(req.path == "/spotify/callback")
        #expect(req.query["code"] == "a b")
        #expect(req.query["state"] == "s1")
    }
}

struct CalendarHintTests {
    typealias S = CalendarHint.Source

    @Test func outlookHintOnlyWithoutAMicrosoftAccount() {
        let icloud = [S(title: "iCloud", isExchange: false)]
        #expect(CalendarHint.hints(sources: icloud, outlookInstalled: true, googleAppInstalled: false, dismissed: []).map(\.kind) == [.outlook])
        #expect(CalendarHint.hints(sources: icloud + [S(title: "Work", isExchange: true)], outlookInstalled: true, googleAppInstalled: false, dismissed: []).isEmpty)
        #expect(CalendarHint.hints(sources: [S(title: "Outlook.com", isExchange: false)], outlookInstalled: true, googleAppInstalled: false, dismissed: []).isEmpty)
        #expect(CalendarHint.hints(sources: icloud, outlookInstalled: false, googleAppInstalled: false, dismissed: []).isEmpty)
    }

    @Test func googleHintOnlyWithoutAGoogleAccount() {
        #expect(CalendarHint.hints(sources: [], outlookInstalled: false, googleAppInstalled: true, dismissed: []).map(\.kind) == [.google])
        #expect(CalendarHint.hints(sources: [S(title: "Gmail", isExchange: false)], outlookInstalled: false, googleAppInstalled: true, dismissed: []).isEmpty)
    }

    @Test func dismissedHintsStayHidden() {
        #expect(CalendarHint.hints(sources: [], outlookInstalled: true, googleAppInstalled: true, dismissed: ["outlook"]).map(\.kind) == [.google])
    }
}
