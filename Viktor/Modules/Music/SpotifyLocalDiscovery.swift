import Foundation
import Network

/// Finds Spotify Connect speakers on your Wi-Fi (Sonos, TVs, Cast speakers…), the way the Spotify
/// app does: they announce themselves as `_spotify-connect._tcp`, and each answers a small
/// `getInfo` request with its name, type and device id. Spotify's Web API often leaves these out
/// of its device list, so Orbit merges them in. macOS asks once for Local Network access.
@MainActor
@Observable
final class SpotifyLocalDiscovery {
    struct Speaker: Identifiable, Equatable {
        let deviceID: String
        let name: String
        let type: String
        /// False only when the speaker says nobody is signed in (Sonos doesn't say, so it counts as linked).
        let linked: Bool
        var id: String { deviceID }
    }

    private(set) var speakers: [Speaker] = []
    private(set) var searching = false

    private var browser: NWBrowser?
    private var probed: Set<String> = []

    func start() {
        guard browser == nil, !ModuleRegistry.isPreview else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_spotify-connect._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.map { r -> (NWEndpoint, String) in
                var path = "/"
                if case .bonjour(let txt) = r.metadata, let p = txt["CPath"], !p.isEmpty { path = p }
                return (r.endpoint, path)
            }
            Task { @MainActor in self?.probe(found) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.stop() } }
        }
        searching = true
        b.start(queue: .global(qos: .utility))
        browser = b
        // Stop looking after a while; speakers that answered stay listed.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            self?.searching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
        probed = []
    }

    private func probe(_ found: [(NWEndpoint, String)]) {
        for (endpoint, path) in found {
            let key = "\(endpoint)"
            guard !probed.contains(key) else { continue }
            probed.insert(key)
            Task.detached {
                guard let data = await Self.get(endpoint, path: Self.infoPath(path)),
                      let speaker = Self.parseInfo(data) else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.speakers.removeAll { $0.deviceID == speaker.deviceID }
                    self.speakers.append(speaker)
                    self.speakers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    // MARK: Helpers (tested)

    nonisolated static func infoPath(_ cpath: String) -> String {
        let base = cpath.hasPrefix("/") ? cpath : "/" + cpath
        return base + (base.contains("?") ? "&" : "?") + "action=getInfo"
    }

    /// Reads a getInfo answer. Spotify's own clients (phones, computers) are skipped: the Web API
    /// already lists them.
    nonisolated static func parseInfo(_ data: Data) -> Speaker? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["deviceID"] as? String, !id.isEmpty,
              let name = json["remoteName"] as? String, !name.isEmpty else { return nil }
        let type = json["deviceType"] as? String ?? "SPEAKER"
        if ["COMPUTER", "SMARTPHONE", "TABLET"].contains(type.uppercased()) { return nil }
        let linked = (json["activeUser"] as? String).map { !$0.isEmpty } ?? true
        return Speaker(deviceID: id, name: name, type: Self.webAPIType(type), linked: linked)
    }

    /// getInfo uses "SPEAKER", "TV", "AVR"…; the Web API uses "Speaker", "TV", "AVR".
    nonisolated static func webAPIType(_ t: String) -> String {
        switch t.uppercased() {
        case "TV": "TV"
        case "AVR": "AVR"
        case "STB": "STB"
        case "AUDIO_DONGLE": "AudioDongle"
        case "GAME_CONSOLE": "GameConsole"
        case "CAST_VIDEO": "CastVideo"
        case "CAST_AUDIO": "CastAudio"
        case "AUTOMOBILE": "Automobile"
        default: "Speaker"
        }
    }

    /// A tiny HTTP/1.0 GET over Network.framework (the speaker closes the connection when done).
    nonisolated static func get(_ endpoint: NWEndpoint, path: String, timeout: TimeInterval = 3) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // IPv4, so the Host header can carry a plain address (Sonos refuses requests without it).
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let conn = NWConnection(to: endpoint, using: params)
            let box = ResultBox(cont)
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                    let total = box.append(data)
                    if done || error != nil || total > 256 * 1024 {
                        conn.cancel()
                        box.finish(Self.body(of: box.buffer))
                    } else {
                        receive()
                    }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let host = Self.hostHeader(conn.currentPath?.remoteEndpoint)
                    let request = "GET \(path) HTTP/1.0\r\nHost: \(host)\r\nAccept: application/json\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in receive() })
                case .failed, .cancelled:
                    box.finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                conn.cancel()
                box.finish(nil)
            }
        }
    }

    /// "192.168.1.196:1400" for the address the connection reached.
    nonisolated static func hostHeader(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "localhost" }
        var h: String
        switch host {
        case .ipv4(let a): h = "\(a)"
        case .ipv6(let a): h = "[\(a)]"
        case .name(let n, _): h = n
        @unknown default: h = "\(host)"
        }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) + (h.hasPrefix("[") ? "]" : "") }
        return "\(h):\(port.rawValue)"
    }

    nonisolated static func body(of response: Data) -> Data? {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: response[..<split.lowerBound], encoding: .utf8) ?? ""
        guard head.hasPrefix("HTTP/1."), head.split(separator: " ").dropFirst().first == "200" else { return nil }
        return response[split.upperBound...]
    }

    /// Resumes a continuation exactly once.
    private final class ResultBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Data?, Never>?
        private let lock = NSLock()
        private var data = Data()
        init(_ c: CheckedContinuation<Data?, Never>) { cont = c }
        var buffer: Data { lock.lock(); defer { lock.unlock() }; return data }
        func append(_ more: Data?) -> Int {
            lock.lock(); defer { lock.unlock() }
            if let more { data.append(more) }
            return data.count
        }
        func finish(_ value: Data?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }
}
