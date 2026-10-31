import Foundation

/// Pure helpers behind the Dev toolbox (tested in AddOnsDevelopersTests).
enum DevTools {
    // MARK: JSON

    struct JSONIssue: Error, Equatable {
        let line: Int?
        let message: String
    }

    /// Checks the text is JSON. Returns the problem (with its line, when known) or nil.
    static func jsonIssue(_ text: String) -> JSONIssue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return JSONIssue(line: nil, message: "Paste some JSON") }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            let desc = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
            var line: Int?
            if let r = desc.range(of: #"line (\d+)"#, options: .regularExpression) {
                line = Int(desc[r].dropFirst(5))
                // Lines count from the trimmed text; add back the blank lines we cut off the top.
                let lead = text.prefix { $0.isWhitespace }.filter(\.isNewline).count
                line = line.map { $0 + lead }
            }
            var message = desc.components(separatedBy: " around line").first ?? ""
            if message.isEmpty || message.hasPrefix("The data couldn") { message = "Not valid JSON" }
            if message.hasSuffix(".") { message.removeLast() }
            return JSONIssue(line: line, message: message)
        }
    }

    /// Re-indents JSON without reordering keys or touching numbers. `indent: nil` minifies.
    static func formatJSON(_ text: String, indent: Int? = 2) -> Result<String, JSONIssue> {
        if let issue = jsonIssue(text) { return .failure(issue) }
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var out = ""
        var level = 0
        var inString = false
        var escaped = false
        let pad: (Int) -> String = { String(repeating: " ", count: (indent ?? 0) * $0) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Keep empty objects and arrays on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out += c == "{" ? "{}" : "[]"
                    i = j
                } else {
                    level += 1
                    out.append(c)
                    if indent != nil { out += "\n" + pad(level) }
                }
            case "}", "]":
                level -= 1
                if indent != nil { out += "\n" + pad(level) }
                out.append(c)
            case ",":
                out.append(c)
                if indent != nil { out += "\n" + pad(level) }
            case ":":
                out += indent != nil ? ": " : ":"
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return .success(out)
    }

    // MARK: Base64 and URL

    static func base64Encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// Accepts standard and URL-safe Base64, with or without padding. Nil when it isn't Base64 or UTF-8 text.
    static func base64Decode(_ text: String) -> String? {
        guard let data = base64Data(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func base64Data(_ text: String) -> Data? {
        var s = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty else { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func urlEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func urlDecode(_ text: String) -> String? { text.removingPercentEncoding }

    // MARK: JWT

    struct JWT: Equatable {
        let header: String
        let payload: String
        let expires: Date?
        let issued: Date?
        func isExpired(now: Date = .now) -> Bool { expires.map { $0 <= now } ?? false }
    }

    /// Decodes a JWT's header and payload. Doesn't check the signature.
    static func decodeJWT(_ token: String) -> JWT? {
        var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let h = base64Data(String(parts[0])), let p = base64Data(String(parts[1])),
              let hText = String(data: h, encoding: .utf8), let pText = String(data: p, encoding: .utf8),
              case .success(let header) = formatJSON(hText), case .success(let payload) = formatJSON(pText)
        else { return nil }
        let claims = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any]
        func date(_ key: String) -> Date? { (claims?[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        return JWT(header: header, payload: payload, expires: date("exp"), issued: date("iat"))
    }

    // MARK: UUID

    static func uuid() -> String { UUID().uuidString.lowercased() }

    // MARK: Timestamps

    /// Reads Unix seconds, Unix milliseconds or an ISO 8601 / "yyyy-MM-dd HH:mm:ss" date. Empty means now.
    static func parseTime(_ text: String, now: Date = .now, timeZone: TimeZone = .current) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return now }
        if let n = Double(t), t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            let digits = t.filter(\.isNumber).count
            // 12+ digits is milliseconds (seconds that big are past year 5000).
            return Date(timeIntervalSince1970: digits >= 12 ? n / 1000 : n)
        }
        if let d = DevFormat.isoDate(t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// The same moment written several ways, as (label, value) rows.
    static func timeRows(_ date: Date, now: Date = .now, timeZone: TimeZone = .current) -> [(String, String)] {
        let iso = ISO8601DateFormatter()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_GB")
        local.timeZone = timeZone
        local.dateFormat = "EEE d MMM yyyy, HH:mm:ss"
        let localISO = ISO8601DateFormatter()
        localISO.timeZone = timeZone
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded())
        return [
            ("Unix seconds", String(seconds)),
            ("Unix ms", String(ms)),
            ("ISO 8601 (UTC)", iso.string(from: date)),
            ("ISO 8601 (local)", localISO.string(from: date)),
            ("Local", local.string(from: date) + " " + (timeZone.abbreviation(for: date) ?? "")),
            ("Relative", relative(date, now: now)),
        ]
    }

    static func relative(_ date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        let a = abs(s)
        if a < 5 { return "now" }
        let amount: String
        switch a {
        case ..<60: amount = "\(a) s"
        case ..<3600: amount = "\(a / 60) min"
        case ..<86400: amount = "\(a / 3600) h"
        default: amount = "\(a / 86400) days"
        }
        return s < 0 ? "\(amount) ago" : "in \(amount)"
    }
}
