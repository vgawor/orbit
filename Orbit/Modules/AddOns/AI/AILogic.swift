import Foundation

/// Pure helpers for the AI add-ons: prompt building and parsing Claude's answers. No UI, no network.
enum AILogic {

    // MARK: Placeholders (Prompt library)

    static let placeholderClipboard = "clipboard"
    static let placeholderDate = "date"

    /// Replaces `{{clipboard}}` and `{{date}}` (any case, spaces allowed inside the braces).
    static func fillPlaceholders(_ text: String, clipboard: String, date: Date, calendar: Calendar = .current) -> String {
        var out = text
        let values = [placeholderClipboard: clipboard, placeholderDate: dayString(date, calendar: calendar)]
        for (name, value) in values {
            let pattern = "\\{\\{\\s*" + name + "\\s*\\}\\}"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
        return out
    }

    /// The placeholder names used in a text (lowercased), e.g. ["clipboard"].
    static func placeholders(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-zA-Z]+)\\s*\\}\\}") else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).lowercased()
        })
    }

    /// "2026-10-28"
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let promptSystem = """
    You are a helpful assistant inside a small panel on a Mac. Answer concisely in plain text. \
    Avoid heavy Markdown: no headings or tables; simple dashes for lists are fine.
    """

    // MARK: Summarize

    enum SummaryLength: String, CaseIterable, Identifiable, Codable {
        case bullets, short, detailed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bullets: "3 bullets"
            case .short: "Short paragraph"
            case .detailed: "Detailed"
            }
        }
        var instruction: String {
            switch self {
            case .bullets: "Summarize the text in exactly 3 bullet points, each starting with \"- \" and at most one sentence."
            case .short: "Summarize the text in one short paragraph of 2–4 sentences."
            case .detailed: "Write a detailed summary: a one-sentence overview, then the key points as a list starting with \"- \", then any decisions, numbers or next steps."
            }
        }
    }

    static let summarizeSystem = """
    You summarize text for a busy person. Be concise and use plain language. Keep names, numbers, \
    dates and amounts exactly as written. Don't add facts that aren't in the text. Write the summary \
    in the same language as the text. Reply with the summary only, in plain text (no headings).
    """

    static func summarizeMessage(_ text: String, length: SummaryLength) -> String {
        "\(length.instruction)\n\n<text>\n\(text)\n</text>"
    }

    // MARK: Translate

    static let languages = ["Swedish", "English", "German", "French", "Spanish", "Norwegian", "Danish", "Finnish",
                            "Italian", "Dutch", "Polish", "Portuguese", "Japanese", "Chinese"]

    static let translateSystem = """
    You are a professional translator. Translate the user's text into the requested language. \
    Keep the meaning, tone and formatting exactly: line breaks, lists, punctuation, names, numbers and URLs. \
    Reply in exactly this format and nothing else:
    SOURCE: <the source language, in English, e.g. Swedish>
    ---
    <the translation>
    """

    static func translateMessage(_ text: String, to language: String) -> String {
        "Translate into \(language).\n\n<text>\n\(text)\n</text>"
    }

    /// Splits "SOURCE: Swedish\n---\n<translation>" into its parts. Falls back to the whole reply as the translation.
    static func parseTranslation(_ raw: String) -> (source: String?, text: String) {
        let reply = stripCodeFences(raw)
        var lines = reply.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("SOURCE:") else {
            return (nil, reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let source = first.trimmingCharacters(in: .whitespaces).dropFirst("SOURCE:".count)
            .trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        while let line = lines.first, line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let sep = lines.first?.trimmingCharacters(in: .whitespaces), sep.count >= 3, sep.allSatisfy({ $0 == "-" }) {
            lines.removeFirst()
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (source.isEmpty ? nil : source, text)
    }

    /// The language in our list matching a detected source name ("swedish", "Svenska (Swedish)") if any.
    static func knownLanguage(_ name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return languages.first { name.contains($0.lowercased()) }
    }

    // MARK: Rewrite

    enum Tone: String, CaseIterable, Identifiable, Codable {
        case clearer, shorter, friendlier, formal, spelling, bullets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clearer: "Clearer"
            case .shorter: "Shorter"
            case .friendlier: "Friendlier"
            case .formal: "More formal"
            case .spelling: "Fix spelling & grammar"
            case .bullets: "Bullet points"
            }
        }
        var instruction: String {
            switch self {
            case .clearer: "Rewrite the text so it's clearer and easier to read. Keep the meaning and roughly the length."
            case .shorter: "Rewrite the text so it's much shorter. Keep every important point."
            case .friendlier: "Rewrite the text in a warmer, friendlier tone. Keep it natural, not over the top."
            case .formal: "Rewrite the text in a more formal, professional tone."
            case .spelling: "Fix spelling, grammar and punctuation only. Change nothing else: keep the wording and style."
            case .bullets: "Turn the text into a short list of bullet points, each starting with \"- \"."
            }
        }
    }

    static let rewriteSystem = """
    You rewrite text for the user. Always answer in the same language as the text. Keep names, numbers \
    and facts exactly. Reply with the rewritten text only: no intro, no quotes, no explanation.
    """

    static func rewriteMessage(_ text: String, tone: Tone) -> String {
        "\(tone.instruction)\n\n<text>\n\(text)\n</text>"
    }

    // MARK: Action items

    struct ActionItem: Identifiable, Equatable, Codable {
        var id = UUID()
        var title: String
        var owner: String?
        /// "YYYY-MM-DD" as Claude gave it.
        var due: String?

        var dueDate: Date? { due.flatMap { AILogic.parseDay($0) } }

        static func == (a: ActionItem, b: ActionItem) -> Bool { a.title == b.title && a.owner == b.owner && a.due == b.due }
    }

    static func actionItemsSystem(today: Date, calendar: Calendar = .current) -> String {
        """
        You extract action items from meeting notes or transcripts. Today is \(dayString(today, calendar: calendar)). \
        Reply with JSON only, no prose and no code fences: an array like \
        [{"title": "Send the offer to Anna", "owner": "Sam", "due": "2026-11-03"}]. \
        "title" is a short imperative task in the language of the notes. "owner" is the person responsible, or null. \
        "due" is a date as YYYY-MM-DD (resolve words like "Friday" from today's date), or null. \
        Only include real tasks someone agreed to do. If there are none, reply [].
        """
    }

    static func actionItemsMessage(_ notes: String) -> String {
        "<notes>\n\(notes)\n</notes>"
    }

    /// Parses Claude's JSON reply. Tolerates code fences, text around the JSON, `{"items": [...]}`,
    /// missing or empty fields. Returns nil when there's no usable JSON at all.
    static func parseActionItems(_ raw: String) -> [ActionItem]? {
        let text = stripCodeFences(raw)
        var json: Any?
        if let data = text.data(using: .utf8) { json = try? JSONSerialization.jsonObject(with: data) }
        if json == nil, let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
           let data = String(text[start...end]).data(using: .utf8) {
            json = try? JSONSerialization.jsonObject(with: data)
        }
        if json == nil, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let data = String(text[start...end]).data(using: .utf8) {
            json = try? JSONSerialization.jsonObject(with: data)
        }
        let list: [Any]
        if let array = json as? [Any] { list = array }
        else if let object = json as? [String: Any] {
            guard let array = (object["items"] ?? object["action_items"] ?? object["actionItems"]) as? [Any] else { return nil }
            list = array
        } else { return nil }

        func clean(_ value: Any?) -> String? {
            guard let s = value as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        return list.compactMap { entry in
            if let title = clean(entry) { return ActionItem(title: title) }
            guard let dict = entry as? [String: Any], let title = clean(dict["title"] ?? dict["task"]) else { return nil }
            let due = clean(dict["due"] ?? dict["due_date"])
            return ActionItem(title: title, owner: clean(dict["owner"] ?? dict["assignee"]),
                              due: due.flatMap { parseDay($0) != nil ? String($0.prefix(10)) : nil })
        }
    }

    /// "2026-11-03" (or the start of an ISO date-time) → that day at 00:00 local time. Nil for anything else.
    static func parseDay(_ s: String, calendar: Calendar = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10 else { return nil }
        let parts = t.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard comps.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: comps)
    }

    /// "- Send the offer (Sam, due 2026-11-03)" lines.
    static func actionItemsList(_ items: [ActionItem]) -> String {
        items.map { item in
            let extra = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
            return "- \(item.title)" + (extra.isEmpty ? "" : " (\(extra.joined(separator: ", ")))")
        }.joined(separator: "\n")
    }

    // MARK: Shared

    /// The first line with words in it, without a list marker or Markdown emphasis, for a Home card.
    static func previewLine(_ text: String, limit: Int = 90) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• ", "– "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                line = String(line[line.index(after: dot)...])
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.contains(where: \.isLetter) || line.contains(where: \.isNumber) else { continue }
            if line.count > limit { line = String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" }
            return line
        }
        return nil
    }

    /// Removes a surrounding Markdown code fence (```json … ```), if any.
    static func stripCodeFences(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let newline = t.firstIndex(of: "\n") { t = String(t[t.index(after: newline)...]) } else { t = String(t.dropFirst(3)) }
        if let fence = t.range(of: "```", options: .backwards) { t = String(t[..<fence.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
