import AppKit
import CryptoKit
import Foundation

/// Spotify Connect: lists your Spotify devices (this Mac, phone, speakers, TV) and moves playback
/// between them, like the speaker menu in the Spotify app.
///
/// Uses Spotify's Web API with the PKCE sign-in for apps without a server: you create a free app at
/// developer.spotify.com, paste its Client ID in Settings → Accounts, and sign in once. The sign-in
/// comes back to Orbit's local server (http://127.0.0.1:47900/spotify/callback) and the refresh
/// token is kept in the Keychain. Switching devices needs Spotify Premium.
@MainActor
@Observable
final class SpotifyConnect {
    static let shared = SpotifyConnect()

    nonisolated static let redirectURI = "http://127.0.0.1:47900/spotify/callback"
    nonisolated static let scopes = "user-read-playback-state user-modify-playback-state"
    nonisolated static let keychainAccount = "spotify"
    private static let clientIDKey = "spotify.clientID"

    struct Device: Identifiable, Equatable, Decodable {
        let id: String
        let name: String
        let type: String
        let isActive: Bool
        let isRestricted: Bool
        let volume: Int?
        /// Found on your Wi-Fi but not in Spotify's device list.
        var onNetwork = false
        /// For speakers found on Wi-Fi: someone is signed in on it, so switching usually works.
        var linked = true

        enum CodingKeys: String, CodingKey {
            case id, name, type
            case isActive = "is_active", isRestricted = "is_restricted", volume = "volume_percent"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decode(String.self, forKey: .name)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Unknown"
            isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
            isRestricted = try c.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
            volume = try c.decodeIfPresent(Int.self, forKey: .volume)
        }

        init(id: String, name: String, type: String, isActive: Bool, isRestricted: Bool = false, volume: Int? = nil,
             onNetwork: Bool = false, linked: Bool = true) {
            self.id = id; self.name = name; self.type = type
            self.isActive = isActive; self.isRestricted = isRestricted; self.volume = volume
            self.onNetwork = onNetwork; self.linked = linked
        }

        /// SF Symbol for the kind of device.
        var symbol: String {
            switch type.lowercased() {
            case "computer": "laptopcomputer"
            case "smartphone": "iphone"
            case "tablet": "ipad"
            case "speaker": "hifispeaker.fill"
            case "tv": "tv"
            case "castvideo", "castaudio": "airplayaudio"
            case "avr", "stb": "hifireceiver.fill"
            case "audiodongle": "cable.connector"
            case "gameconsole": "gamecontroller.fill"
            case "automobile": "car.fill"
            case "smartwatch": "applewatch"
            default: "speaker.wave.2.fill"
            }
        }
    }

    /// Your own Client ID (Settings → Accounts), or the one shipped with Orbit (SpotifyClientID in Info.plist).
    var clientID: String = UserDefaults.standard.string(forKey: SpotifyConnect.clientIDKey).flatMap { $0.isEmpty ? nil : $0 }
        ?? (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "") {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }

    private(set) var devices: [Device] = []
    /// Spotify speakers on your Wi-Fi (Sonos, TVs…), merged into `devices`.
    let nearby = SpotifyLocalDiscovery()
    private var accountDevices: [Device] = []
    private var playingDevice: Device?
    private(set) var loading = false
    private(set) var switchingTo: String?
    /// A short message when something went wrong ("Needs Spotify Premium"…).
    private(set) var problem: String?
    private(set) var connected = false

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var pending: (state: String, verifier: String)?

    init() {}

    /// Layout snapshots only: a connected account with a few devices.
    func previewFill() {
        connected = true
        devices = [
            Device(id: "1", name: "Sam's MacBook Pro", type: "Computer", isActive: false),
            Device(id: "2", name: "Living room", type: "Speaker", isActive: true, volume: 40),
            Device(id: "3", name: "iPhone", type: "Smartphone", isActive: false),
            Device(id: "4", name: "Samsung TV", type: "TV", isActive: false, isRestricted: true),
            Device(id: "5", name: "Milou Sonos", type: "Speaker", isActive: false, onNetwork: true, linked: true),
            Device(id: "6", name: "Samsung Projector LSP3", type: "TV", isActive: false, onNetwork: true, linked: false),
        ]
    }

    /// Reads the saved sign-in (after the Keychain warm-up at launch).
    func refreshState() {
        connected = Secrets.get(Self.keychainAccount) != nil
    }

    var hasClientID: Bool { !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Sign-in (PKCE)

    func connect() {
        guard hasClientID else { problem = "Add your Spotify Client ID first."; return }
        let verifier = Self.randomString(64)
        let state = Self.randomString(16)
        pending = (state, verifier)
        problem = nil
        guard let url = Self.authorizeURL(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          challenge: Self.challenge(for: verifier), state: state) else { return }
        NSWorkspace.shared.open(url)
    }

    func disconnect() {
        Secrets.set(nil, for: Self.keychainAccount)
        accessToken = nil
        devices = []
        connected = false
    }

    /// Called by the local server when Spotify sends the browser back. Returns the page to show.
    func handleCallback(query: [String: String]) async -> String {
        guard let pending, query["state"] == pending.state else {
            return Self.page("That sign-in link has expired", "Go back to Orbit and click Connect Spotify again.")
        }
        self.pending = nil
        if let error = query["error"] {
            problem = error == "access_denied" ? "Spotify sign-in was cancelled." : "Spotify said: \(error)"
            return Self.page("Not connected", "You can close this tab.")
        }
        guard let code = query["code"] else { return Self.page("Not connected", "Spotify didn't send a code.") }
        do {
            try await exchange(code: code, verifier: pending.verifier)
            connected = true
            problem = nil
            await loadDevices()
            return Self.page("Spotify is connected", "You can close this tab and pick a device from the notch.")
        } catch {
            problem = "Sign-in failed: \(error.localizedDescription)"
            return Self.page("Not connected", error.localizedDescription)
        }
    }

    // MARK: Devices

    func loadDevices() async {
        guard connected else { return }
        loading = true
        defer { loading = false }
        nearby.start()
        do {
            let data = try await api("GET", "/me/player/devices")
            struct List: Decodable { let devices: [Device] }
            accountDevices = try JSONDecoder().decode(List.self, from: data).devices.filter { !$0.id.isEmpty }
            // What's playing now names its device even when the list above leaves it out (Sonos…).
            struct Player: Decodable { let device: Device? }
            let now = try? await api("GET", "/me/player")
            playingDevice = now.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(Player.self, from: $0).device }
            mergeDevices()
            problem = devices.isEmpty ? "No devices found. Open Spotify on the device you want to use." : nil
        } catch {
            problem = Self.describe(error)
        }
    }

    /// Spotify's list + the device playing now + speakers found on Wi-Fi, without duplicates.
    func mergeDevices() {
        devices = Self.merge(account: accountDevices, playing: playingDevice, nearby: nearby.speakers)
    }

    static func merge(account: [Device], playing: Device?, nearby: [SpotifyLocalDiscovery.Speaker]) -> [Device] {
        func same(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedSame }
        var out = account
        // Spotify sometimes reports the playing device (often a Sonos) without an id; match it by name.
        let playingNearby = playing.flatMap { p in nearby.first { same($0.name, p.name) } }
        if let playing, !out.contains(where: { $0.id == playing.id && !playing.id.isEmpty }) {
            if let s = playingNearby {
                out.insert(Device(id: s.deviceID, name: s.name, type: s.type, isActive: true, volume: playing.volume), at: 0)
            } else {
                let id = playing.id.isEmpty ? "playing:\(playing.name)" : playing.id
                out.insert(Device(id: id, name: playing.name, type: playing.type, isActive: true,
                                  isRestricted: playing.isRestricted, volume: playing.volume), at: 0)
            }
        }
        for s in nearby {
            let known = out.contains { $0.id == s.deviceID || same($0.name, s.name) }
            guard !known else { continue }
            out.append(Device(id: s.deviceID, name: s.name, type: s.type, isActive: false,
                              onNetwork: true, linked: s.linked))
        }
        // Playing first, then your account's devices, then the ones found on Wi-Fi.
        return out.enumerated().sorted { a, b in
            let ka = (a.element.isActive ? 0 : a.element.onNetwork ? 2 : 1, a.offset)
            let kb = (b.element.isActive ? 0 : b.element.onNetwork ? 2 : 1, b.offset)
            return ka < kb
        }.map(\.element)
    }

    /// Moves playback to `device`, keeping it playing.
    func transfer(to device: Device) async {
        switchingTo = device.id
        defer { switchingTo = nil }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["device_ids": [device.id], "play": true])
            _ = try await api("PUT", "/me/player", body: body)
            // Spotify takes a moment to switch; then show the new active device.
            try? await Task.sleep(for: .milliseconds(700))
            await loadDevices()
        } catch SpotifyConnect.APIError.status(404, _) where device.onNetwork {
            problem = "Open Spotify and choose \(device.name) once. After that you can switch to it from here."
        } catch {
            problem = Self.describe(error)
        }
    }

    // MARK: Web API

    enum APIError: LocalizedError {
        case status(Int, String)
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not connected to Spotify."
            case .status(let code, let message): "Spotify \(code): \(message)"
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case APIError.status(403, _): "Switching devices needs Spotify Premium."
        case APIError.status(404, _): "That device isn't available right now. Open Spotify on it and try again."
        case APIError.status(401, _), APIError.notSignedIn: "Spotify sign-in expired. Connect again in Settings → Accounts."
        case APIError.status(429, _): "Spotify is busy. Try again in a moment."
        default: error.localizedDescription
        }
    }

    private func api(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "error"
            if status == 401 { accessToken = nil }
            throw APIError.status(status, message)
        }
        return data
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, expiresAt > .now.addingTimeInterval(30) { return accessToken }
        guard let refresh = Secrets.get(Self.keychainAccount) else { throw APIError.notSignedIn }
        try await token(form: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw APIError.notSignedIn }
        return accessToken
    }

    private func exchange(code: String, verifier: String) async throws {
        try await token(form: ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                               "client_id": clientID, "code_verifier": verifier])
    }

    private func token(form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200, let access = json["access_token"] as? String else {
            if status == 400, (json["error"] as? String) == "invalid_grant" { disconnect() }
            throw APIError.status(status == 400 ? 401 : status, json["error_description"] as? String ?? "sign-in failed")
        }
        accessToken = access
        expiresAt = .now.addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3600))
        if let refresh = json["refresh_token"] as? String { Secrets.set(refresh, for: Self.keychainAccount) }
    }

    // MARK: Helpers (tested)

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: scopes),
            .init(name: "state", value: state),
        ]
        return c.url
    }

    /// PKCE: base64url(SHA-256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func page(_ title: String, _ text: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Orbit</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;background:#0d0b18;color:#fff;
        font:16px -apple-system,system-ui,sans-serif}main{text-align:center}h1{font-size:28px;margin:0 0 8px}
        p{color:#ffffffaa;margin:0}</style></head><body><main><h1>\(esc(title))</h1><p>\(esc(text))</p></main></body></html>
        """
    }
}
