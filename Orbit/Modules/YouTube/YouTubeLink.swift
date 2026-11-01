import Foundation

/// A YouTube video picked out of a link: the 11-character id and where to start.
struct YouTubeLink: Equatable, Sendable {
    let id: String
    /// Seconds into the video, from `t=` / `start=` (0 when none).
    var start: Int = 0

    var watchURL: URL {
        var s = "https://www.youtube.com/watch?v=\(id)"
        if start > 0 { s += "&t=\(start)s" }
        return URL(string: s)!
    }

    /// Understands youtube.com/watch?v=, youtu.be/, /shorts/, /embed/, /live/, /v/, m./music. hosts,
    /// youtube-nocookie.com, links without a scheme, extra query params and `t=90` / `t=1m30s` / `#t=…`.
    static func parse(_ text: String) -> YouTubeLink? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dragged text can carry a title line before/after the link; take the first token that looks like one.
        if let token = t.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.lowercased().contains("youtu") }) {
            t = String(token)
        }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let comps = URLComponents(string: t), let rawHost = comps.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = comps.path.split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }

        var candidate: String?
        if host == "youtu.be" {
            candidate = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" {
            if path.first == "watch" || path.isEmpty {
                candidate = query["v"]
            } else if path.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(path[0]) {
                candidate = path[1]
            } else if path.first == "attribution_link", let u = query["u"], let inner = URLComponents(string: "https://youtube.com" + u) {
                candidate = inner.queryItems?.first { $0.name == "v" }?.value
            }
        }
        guard let id = candidate, isValidID(id) else { return nil }

        // Start time: ?t= / ?start= / #t=
        var timeText = query["t"] ?? query["start"] ?? query["time_continue"]
        if timeText == nil, let frag = comps.fragment, frag.hasPrefix("t=") { timeText = String(frag.dropFirst(2)) }
        return YouTubeLink(id: id, start: timeText.map(seconds(from:)) ?? 0)
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds.
    static func seconds(from text: String) -> Int {
        let t = text.lowercased()
        if let n = Int(t) { return max(0, n) }
        var total = 0, number = ""
        for c in t {
            if c.isNumber { number.append(c); continue }
            let n = Int(number) ?? 0
            number = ""
            switch c {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: break
            }
        }
        if let n = Int(number) { total += n }
        return max(0, total)
    }
}
