import Foundation

/// Where the app's local API listens and where its private token lives.
/// The API only accepts connections from this Mac (127.0.0.1) and every request needs the token.
public enum APIConfig {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 47900
    public static var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// ~/Library/Application Support/Orbit. Earlier builds used a "Viktor" folder; it's moved
    /// over the first time this runs, so notes, tasks and settings come along.
    public static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportFolder(in: base)
    }

    static func supportFolder(in base: URL) -> URL {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("Orbit", isDirectory: true)
        let old = base.appendingPathComponent("Viktor", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Readable only by you (permissions 600).
    public static var tokenURL: URL { supportFolder.appendingPathComponent("api-token") }

    public static func readToken() -> String? {
        (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Used by the app: reuse the saved token or make a new random one.
    public static func loadOrCreateToken() -> String {
        if let t = readToken(), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}

/// Something your scripts show in the notch: a progress bar, a status, a result.
public struct APIItem: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case active, waiting, success, error }

    public var id: String
    public var title: String
    public var subtitle: String?
    /// 0…1, or nil for no bar.
    public var progress: Double?
    public var status: Status
    /// Seconds until it disappears. Nil keeps it until removed.
    public var ttl: Double?
    public var source: String?
    public var updated: Date

    public init(id: String = UUID().uuidString, title: String, subtitle: String? = nil, progress: Double? = nil,
                status: Status = .active, ttl: Double? = nil, source: String? = nil, updated: Date = .now) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.progress = progress
        self.status = status; self.ttl = ttl; self.source = source; self.updated = updated
    }

    public var expiresAt: Date? { ttl.map { updated.addingTimeInterval($0) } }
}

/// A question with buttons. The call waits until someone clicks or the timeout passes.
public struct AskRequest: Codable, Sendable {
    public var title: String
    public var subtitle: String?
    public var actions: [String]
    public var timeout: Double?

    public init(title: String, subtitle: String? = nil, actions: [String], timeout: Double? = nil) {
        self.title = title; self.subtitle = subtitle; self.actions = actions; self.timeout = timeout
    }
}

public struct AskResponse: Codable, Sendable {
    /// The button that was clicked, or nil when nobody answered in time.
    public var choice: String?
    public init(choice: String?) { self.choice = choice }
}

public struct StatusResponse: Codable, Sendable {
    public var ok: Bool
    public var version: String
    public var items: Int
    public init(ok: Bool, version: String, items: Int) { self.ok = ok; self.version = version; self.items = items }
}

public enum APIJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
