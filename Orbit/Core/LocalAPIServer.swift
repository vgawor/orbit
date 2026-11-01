import Foundation
import Network
import OrbitKit

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var query: [String: String] = [:]

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Returns nil until the full request (headers + body) has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(requestLine[1])
        let path = target.components(separatedBy: "?")[0]
        var query: [String: String] = [:]
        for item in URLComponents(string: target)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)), query: query)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func html(_ page: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(page.utf8), contentType: "text/html; charset=utf-8")
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? APIJSON.encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 408: "Request Timeout", 413: "Payload Too Large"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A tiny HTTP server bound to 127.0.0.1. Every request must carry `Authorization: Bearer <token>`,
/// and requests from web pages (with an Origin header) are refused.
final class LocalAPIServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "orbit.api")
    private let token: String
    private let handler: Handler
    private var listener: NWListener?
    private static let maxRequestBytes = 1_000_000

    /// Set on the main thread so Settings can show whether the API is up.
    @MainActor private(set) var isRunning = false
    @MainActor private(set) var lastError: String?

    init(token: String, handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    @MainActor
    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .init(APIConfig.host), port: .init(rawValue: APIConfig.port)!)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true; self?.lastError = nil
                    case .failed(let e): self?.isRunning = false; self?.lastError = e.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.send(.error(413, "Request too large"), on: conn)
            } else if let request = HTTPRequest.parse(buffer) {
                self.handle(request, on: conn)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on conn: NWConnection) {
        // Spotify sends the browser back here after you sign in. A browser can't carry the API
        // token, so this one page is open; it only completes a sign-in Orbit itself started.
        if request.method == "GET", request.path == "/spotify/callback" {
            Task {
                let page = await SpotifyConnect.shared.handleCallback(query: request.query)
                self.send(.html(page), on: conn)
            }
            return
        }
        if request.header("origin") != nil {
            return send(.error(403, "Browser requests are not allowed"), on: conn)
        }
        guard Self.constantTimeEqual(request.header("authorization") ?? "", "Bearer \(token)") else {
            return send(.error(401, "Missing or wrong token"), on: conn)
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.send(response, on: conn)
        }
    }

    private func send(_ response: HTTPResponse, on conn: NWConnection) {
        conn.send(content: response.serialized(), completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
