import AppKit

/// Reads mail from Apple Mail on this Mac (every account Mail has: iCloud, Gmail, Exchange…), for
/// bots like Inbox. Read-only: nothing is moved, marked or sent. macOS asks once for permission
/// to control Mail (Privacy & Security → Automation).
enum AppleMail {
    struct Summary: Equatable {
        let id: String
        let sender: String
        let subject: String
        /// Seconds since it arrived (locale-free, unlike AppleScript dates).
        let age: Int
        let read: Bool
    }

    /// AppleScript isn't thread-safe; every script runs here, one at a time.
    private static let queue = DispatchQueue(label: "orbit.apple-mail")
    private static let field = "\u{1F}", record = "\u{1E}"

    /// Recent inbox messages, newest first.
    static func recent(days: Int, unreadOnly: Bool, query: String?, limit: Int = 30) async -> Result<[Summary], MailError> {
        let d = min(max(days, 1), 14)
        let script = """
        set cutoff to (current date) - (\(d) * days)
        set out to {}
        with timeout of 40 seconds
            tell application "Mail"
                set msgs to (messages of inbox whose date received > cutoff)
                set n to 0
                repeat with m in msgs
                    set n to n + 1
                    if n > 150 then exit repeat
                    set age to ((current date) - (date received of m)) as integer
                    set end of out to ((id of m) as string) & (ASCII character 31) & (sender of m) & (ASCII character 31) & (subject of m) & (ASCII character 31) & (age as string) & (ASCII character 31) & ((read status of m) as string)
                end repeat
            end tell
        end timeout
        set AppleScript's text item delimiters to (ASCII character 30)
        return out as string
        """
        switch await run(script) {
        case .failure(let e): return .failure(e)
        case .success(let text):
            var list = parse(text)
            if unreadOnly { list = list.filter { !$0.read } }
            if let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty {
                list = list.filter { $0.subject.lowercased().contains(q) || $0.sender.lowercased().contains(q) }
            }
            return .success(Array(list.sorted { $0.age < $1.age }.prefix(limit)))
        }
    }

    /// One message: who sent it, to whom, and its text (cut to 6000 characters).
    static func message(id: String) async -> Result<String, MailError> {
        let safe = id.filter(\.isNumber)
        guard !safe.isEmpty else { return .failure(.notFound) }
        let script = """
        with timeout of 30 seconds
            tell application "Mail"
                set m to first message of inbox whose id is \(safe)
                set r to {}
                repeat with x in (to recipients of m)
                    set end of r to (address of x)
                end repeat
                set AppleScript's text item delimiters to ", "
                return "From: " & (sender of m) & linefeed & "To: " & (r as string) & linefeed & "Subject: " & (subject of m) & linefeed & linefeed & (content of m)
            end tell
        end timeout
        """
        switch await run(script) {
        case .failure(let e): return .failure(e)
        case .success(let text): return .success(String(text.prefix(6000)))
        }
    }

    enum MailError: Error, Equatable {
        case notAllowed, notFound, failed(String)
        var message: String {
            switch self {
            case .notAllowed: "Orbit isn't allowed to read Mail. You can allow it in System Settings → Privacy & Security → Automation → Orbit → Mail."
            case .notFound: "No such email in the inbox."
            case .failed(let why): "Couldn't read Apple Mail: \(why)"
            }
        }
    }

    static func parse(_ text: String) -> [Summary] {
        text.components(separatedBy: record).compactMap { row in
            let f = row.components(separatedBy: field)
            guard f.count == 5, let age = Int(f[3].trimmingCharacters(in: .whitespaces)) else { return nil }
            return Summary(id: f[0], sender: f[1], subject: f[2], age: age, read: f[4] == "true")
        }
    }

    /// "2 h ago", for the bot.
    static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<3600: "\(max(seconds / 60, 1)) min ago"
        case ..<86400: "\(seconds / 3600) h ago"
        default: "\(seconds / 86400) d ago"
        }
    }

    /// Opens Mail in the background if it isn't running, so a scheduled bot can read it.
    @MainActor
    private static func ensureRunning() async {
        let id = "com.apple.mail"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try? await Task.sleep(for: .seconds(4))
    }

    private static func run(_ source: String) async -> Result<String, MailError> {
        await ensureRunning()
        return await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let text = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
                    // -1743: not allowed to send Apple Events. -1728: can't get that message.
                    cont.resume(returning: .failure(code == -1743 ? .notAllowed : code == -1728 ? .notFound : .failed(text)))
                } else {
                    cont.resume(returning: .success(result?.stringValue ?? ""))
                }
            }
        }
    }
}
