import Foundation
import Testing
@testable import Viktor

@MainActor
struct SpotifyNearbyTests {
    typealias D = SpotifyConnect.Device
    typealias S = SpotifyLocalDiscovery.Speaker

    @Test func playingDeviceAndWiFiSpeakersAreMergedOnce() {
        let account = [D(id: "mac", name: "MacBook", type: "Computer", isActive: false)]
        let playing = D(id: "kok", name: "Kök", type: "Speaker", isActive: true)
        let nearby = [S(deviceID: "kok", name: "Kök", type: "Speaker", linked: true),
                      S(deviceID: "sonos", name: "Milou Sonos", type: "Speaker", linked: false),
                      S(deviceID: "other-id", name: "macbook", type: "Speaker", linked: true)]
        let merged = SpotifyConnect.merge(account: account, playing: playing, nearby: nearby)
        #expect(merged.map(\.id) == ["kok", "mac", "sonos"])
        #expect(merged[0].isActive && !merged[0].onNetwork)
        #expect(merged[2].onNetwork && !merged[2].linked)
    }

    @Test func getInfoAnswersBecomeSpeakers() throws {
        let json = #"{"status":101,"deviceID":"abc123","remoteName":"Vardagsrum","deviceType":"SPEAKER","activeUser":"viktor"}"#
        let s = try #require(SpotifyLocalDiscovery.parseInfo(Data(json.utf8)))
        #expect(s.name == "Vardagsrum" && s.type == "Speaker" && s.linked)
        // Sonos doesn't say who's signed in: counts as linked.
        let sonos = #"{"deviceID":"1486","remoteName":"Kök","deviceType":"SPEAKER","brandDisplayName":"Sonos"}"#
        #expect(SpotifyLocalDiscovery.parseInfo(Data(sonos.utf8))?.linked == true)
        #expect(SpotifyLocalDiscovery.parseInfo(Data(#"{"deviceID":"x","remoteName":"Y","activeUser":""}"#.utf8))?.linked == false)
        #expect(SpotifyLocalDiscovery.parseInfo(Data(#"{"deviceID":"x","remoteName":"Phone","deviceType":"SMARTPHONE"}"#.utf8)) == nil)
        #expect(SpotifyLocalDiscovery.parseInfo(Data("nope".utf8)) == nil)
        #expect(SpotifyLocalDiscovery.webAPIType("TV") == "TV")
    }

    @Test func aPlayingSonosWithoutAnIdIsMatchedByName() {
        let playing = D(id: "", name: "Kök", type: "Speaker", isActive: true, volume: 30)
        let merged = SpotifyConnect.merge(account: [], playing: playing,
                                          nearby: [S(deviceID: "1486", name: "Kök", type: "Speaker", linked: true)])
        #expect(merged.count == 1)
        #expect(merged[0].id == "1486" && merged[0].isActive && !merged[0].onNetwork)
        // Not found on Wi-Fi: still shown as playing.
        let alone = SpotifyConnect.merge(account: [], playing: playing, nearby: [])
        #expect(alone.first?.name == "Kök" && alone.first?.isActive == true)
    }

    @Test func infoPathAndResponseBody() {
        #expect(SpotifyLocalDiscovery.infoPath("/zc") == "/zc?action=getInfo")
        #expect(SpotifyLocalDiscovery.infoPath("spotifyconnect/zeroconf") == "/spotifyconnect/zeroconf?action=getInfo")
        let ok = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8)
        #expect(SpotifyLocalDiscovery.body(of: ok) == Data("{\"a\":1}".utf8))
        #expect(SpotifyLocalDiscovery.body(of: Data("HTTP/1.0 404 Not Found\r\n\r\n".utf8)) == nil)
    }
}
