import AppKit
import SwiftUI
import ViktorKit

/// One agent task Orbit started: Claude Code working in a folder, shown as a chat.
@MainActor
@Observable
final class AgentRun: Identifiable {
    enum State: Equatable { case starting, working, waiting, idle, failed(String), stopped }

    struct Message: Identifiable, Equatable {
        enum Kind: Equatable { case user, assistant, tool, note, approval }
        let id = UUID()
        var kind: Kind
        var text: String
        var detail: String? = nil
        /// For approvals: nil while waiting, then "Allowed" / "Denied" / "No answer".
        var decided: String? = nil
        var approvalID: UUID? = nil
    }

    let id = UUID().uuidString
    let folder: URL
    let started = Date.now
    var messages: [Message] = []
    var state: State = .starting
    var claudeSessionID: String?
    var cost: Double = 0
    var process: Process?
    /// Last line Claude Code printed on its error output, for when a run fails.
    var errorTail = ""

    var name: String { folder.lastPathComponent }
    var title: String { messages.first { $0.kind == .user }?.text ?? "New task" }
    var isBusy: Bool { state == .starting || state == .working || state == .waiting }
    var lastLine: String {
        switch state {
        case .waiting: return "Waiting for your OK"
        case .failed(let why): return why
        case .stopped: return "Stopped"
        default:
            let text = messages.last(where: { $0.kind != .user })?.text ?? "Starting…"
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }
    }

    init(folder: URL) { self.folder = folder }

    /// Reads one line of `claude -p --output-format stream-json` output.
    func ingest(_ line: String) {
        for event in Self.parse(line) {
            switch event {
            case .session(let id):
                claudeSessionID = id
                if state == .starting { state = .working }
            case .text(let text):
                messages.append(Message(kind: .assistant, text: text))
            case .tool(let name, let summary):
                messages.append(Message(kind: .tool, text: summary, detail: name))
            case .toolError(let text):
                messages.append(Message(kind: .note, text: text))
            case .result(let id, let text, let isError, let cost):
                if let id { claudeSessionID = id }
                self.cost += cost
                if isError {
                    if Self.isSignInError(text) {
                        state = .failed(Self.signInMessage)
                        // Replace the raw error in the chat with what to do about it.
                        if let i = messages.lastIndex(where: { $0.kind == .assistant && $0.text == text }) { messages.remove(at: i) }
                        messages.append(Message(kind: .note, text: Self.signInHelp, detail: "signin"))
                    } else {
                        state = .failed(text.isEmpty ? "Claude Code stopped with an error" : text)
                    }
                } else {
                    // The final answer usually repeats the last message; only add it if it's new.
                    if !text.isEmpty, messages.last(where: { $0.kind == .assistant })?.text != text {
                        messages.append(Message(kind: .assistant, text: text))
                    }
                    state = .idle
                }
            }
        }
    }

    // MARK: Sign-in problems

    static let signInMessage = "Claude Code needs you to sign in again"
    static let signInHelp = "Claude Code's sign-in has expired. Open Terminal, run claude, type /login and follow the steps. Then send a message here to try again."

    nonisolated static func isSignInError(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("authenticate") || t.contains("oauth") || t.contains("/login") || t.contains("not logged in")
            || t.contains("invalid api key")
    }

    // MARK: Parsing (pure, tested)

    enum Event: Equatable {
        case session(String)
        case text(String)
        case tool(name: String, summary: String)
        case toolError(String)
        case result(sessionID: String?, text: String, isError: Bool, cost: Double)
    }

    nonisolated static func parse(_ line: String) -> [Event] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }
        switch type {
        case "system":
            if json["subtype"] as? String == "init", let id = json["session_id"] as? String { return [.session(id)] }
            return []
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    return .tool(name: name, summary: describeTool(name, block["input"] as? [String: Any]))
                default:
                    return nil
                }
            }
        case "user":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", block["is_error"] as? Bool == true else { return nil }
                let text = (block["content"] as? String) ?? "A step didn't work"
                return .toolError(String(text.prefix(160)))
            }
        case "result":
            return [.result(sessionID: json["session_id"] as? String,
                            text: (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            isError: json["is_error"] as? Bool ?? false,
                            cost: json["total_cost_usd"] as? Double ?? 0)]
        default:
            return []
        }
    }

    /// "Running npm test", "Editing App.swift"…
    nonisolated static func describeTool(_ name: String?, _ input: [String: Any]?) -> String {
        let file = (input?["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing \(file ?? "a file")"
        case "Read": return "Reading \(file ?? "a file")"
        case "Bash":
            let cmd = (input?["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running \(cmd.prefix(80))"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch": return "Looking things up"
        case "Task", "Agent": return "Working with a helper agent"
        case "TodoWrite": return "Planning the steps"
        case let other?: return "Using \(other)"
        case nil: return "Working"
        }
    }
}

/// Starts and steers Claude Code sessions from the notch, and answers their approval questions.
@MainActor
@Observable
final class AgentRunner {
    private(set) var runs: [AgentRun] = []
    var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: "agents.recentFolders") ?? [] {
        didSet { UserDefaults.standard.set(Array(recentFolders.prefix(6)), forKey: "agents.recentFolders") }
    }

    private struct Pending {
        let runID: String?
        let continuation: CheckedContinuation<AgentPermission.Decision, Never>
    }
    private var pending: [UUID: Pending] = [:]
    private let alerts: AlertCenter

    init(alerts: AlertCenter) { self.alerts = alerts }

    var waitingCount: Int { runs.filter { $0.state == .waiting }.count }
    var workingCount: Int { runs.filter { $0.state == .working || $0.state == .starting }.count }
    func run(_ id: String?) -> AgentRun? { runs.first { $0.id == id } }
    /// Claude Code session ids that belong to Orbit's own runs (so the hook list doesn't show them twice).
    var ownSessionIDs: Set<String> { Set(runs.compactMap(\.claudeSessionID)) }

    // MARK: Finding Claude Code

    /// The `claude` command. GUI apps don't get your shell's PATH, so look in the usual places.
    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // Ask a login shell, which knows your PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The `viktor` helper that answers Claude Code's approval hook.
    static func helperPath() -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/viktor").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let linked = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/viktor").path
        return FileManager.default.isExecutableFile(atPath: linked) ? linked : nil
    }

    /// Settings file with the approval hook, passed to `claude --settings`. Your own
    /// ~/.claude/settings.json is never changed.
    private func settingsFile() throws -> URL {
        guard let helper = Self.helperPath() else {
            throw NSError(domain: "Orbit.Agents", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Orbit's helper is missing, so it can't ask you before Claude changes things. Install Orbit with scripts/install.sh."])
        }
        let dir = Storage.folder
        let url = dir.appendingPathComponent("agent-settings.json")
        let command = "'\(helper.replacingOccurrences(of: "'", with: "'\\''"))' hook permission"
        try AgentPermission.settingsJSON(hookCommand: command).write(to: url, options: .atomic)
        return url
    }

    // MARK: Start, continue, stop

    /// Starts Claude Code in `folder` with your instruction. Returns the run, or an error to show.
    func start(in folder: URL, prompt: String) -> Result<AgentRun, Error> {
        let run = AgentRun(folder: folder)
        runs.insert(run, at: 0)
        recentFolders = [folder.path] + recentFolders.filter { $0 != folder.path }
        do {
            try launch(run, prompt: prompt)
            return .success(run)
        } catch {
            runs.removeAll { $0.id == run.id }
            return .failure(error)
        }
    }

    /// Sends a follow-up message: continues the same Claude Code session.
    func send(_ text: String, to run: AgentRun) {
        guard !run.isBusy else { return }
        do { try launch(run, prompt: text) } catch {
            run.messages.append(.init(kind: .note, text: error.localizedDescription))
        }
    }

    /// Stops the run like Ctrl-C: the current step ends and the session can be continued later.
    func stop(_ run: AgentRun) {
        guard let p = run.process, p.isRunning else { return }
        p.interrupt()
        Task { [weak run] in
            try? await Task.sleep(for: .seconds(3))
            if let p = run?.process, p.isRunning { p.terminate() }
        }
        // Anything it was waiting on is denied.
        for (id, item) in pending where item.runID == run.id { decide(id, .deny("Stopped in Orbit"), label: "Stopped") }
        run.state = .stopped
    }

    func remove(_ run: AgentRun) {
        stop(run)
        runs.removeAll { $0.id == run.id }
    }

    private func launch(_ run: AgentRun, prompt: String) throws {
        guard let claude = Self.findClaude() else {
            throw NSError(domain: "Orbit.Agents", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Claude Code isn't installed, or Orbit can't find it. Install it from claude.com/code and sign in once in Terminal."])
        }
        let settings = try settingsFile()
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--settings", settings.path]
        if let session = run.claudeSessionID { args += ["--resume", session] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = run.folder
        var env = ProcessInfo.processInfo.environment
        let claudeDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        env["PATH"] = [claudeDir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env[AgentPermission.runEnv] = run.id
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let runID = run.id
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300)) // let the last output lines arrive first
                self?.finished(runID, status: status)
            }
        }
        run.messages.append(.init(kind: .user, text: prompt))
        run.state = run.claudeSessionID == nil ? .starting : .working
        try p.run()
        run.process = p

        let handle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.ingest(line, runID: runID)
                }
            } catch {}
        }
        // Keep reading the error output too, so it never fills up and stalls Claude Code.
        Task.detached { [weak self] in
            do {
                for try await line in errHandle.bytes.lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    await self?.noteError(line, runID: runID)
                }
            } catch {}
        }
    }

    private func ingest(_ line: String, runID: String) {
        run(runID)?.ingest(line)
    }

    private func noteError(_ line: String, runID: String) {
        run(runID)?.errorTail = String(line.prefix(200))
    }

    private func finished(_ runID: String, status: Int32) {
        guard let run = run(runID) else { return }
        run.process = nil
        switch run.state {
        case .starting, .working, .waiting:
            if status == 0 {
                run.state = .idle
            } else {
                let why = run.errorTail.isEmpty ? "Claude Code stopped (code \(status))" : run.errorTail
                run.state = .failed(why)
            }
        default: break
        }
        if case .idle = run.state, !NSApp.isActive {
            alerts.post(NotchAlert(symbol: "checkmark", tint: Tokens.live, title: "Agent finished · \(run.name)",
                                   subtitle: run.lastLine, actions: [.init(title: "OK", isPrimary: true)], duration: 6, sound: "Glass"))
        }
    }

    // MARK: Approvals

    /// Called by the API when Claude Code wants your OK. Waits for Allow or Deny.
    func requestPermission(_ body: Data) async -> AgentPermission.Decision {
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let tool = json["tool_name"] as? String ?? "a tool"
        let input = json["tool_input"] as? [String: Any]
        let runID = (json["orbit_run_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let session = json["session_id"] as? String
        let run = run(runID) ?? runs.first { $0.claudeSessionID != nil && $0.claudeSessionID == session }
        let what = AgentRun.describeTool(tool, input)
        let full = (input?["command"] as? String) ?? (input?["file_path"] as? String) ?? (input?["url"] as? String)

        let id = UUID()
        run?.messages.append(.init(kind: .approval, text: what, detail: full, approvalID: id))
        run?.state = .waiting

        return await withCheckedContinuation { cont in
            pending[id] = Pending(runID: run?.id, continuation: cont)
            alerts.post(NotchAlert(symbol: "hand.raised.fill", tint: Tokens.attention,
                                   title: "Allow? \(what)", subtitle: run.map { "Agent · \($0.name)" } ?? "Claude Code",
                                   actions: [
                                       .init(title: "Deny") { [weak self] in self?.decide(id, .deny("Denied in Orbit"), label: "Denied") },
                                       .init(title: "Allow", isPrimary: true) { [weak self] in self?.decide(id, .allow, label: "Allowed") },
                                   ],
                                   duration: AgentPermission.answerTimeout, sound: "Tink"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(AgentPermission.answerTimeout))
                self?.decide(id, .deny("No answer in Orbit, so it wasn't allowed."), label: "No answer")
            }
        }
    }

    /// Answers a waiting approval (from the chat, the alert, or the timeout). Only the first answer counts.
    func decide(_ id: UUID, _ decision: AgentPermission.Decision, label: String) {
        guard let item = pending.removeValue(forKey: id) else { return }
        if let run = run(item.runID) {
            if let i = run.messages.firstIndex(where: { $0.approvalID == id }) { run.messages[i].decided = label }
            if run.state == .waiting, !pending.values.contains(where: { $0.runID == run.id }) { run.state = .working }
        }
        item.continuation.resume(returning: decision)
    }

    func isPending(_ id: UUID?) -> Bool { id.map { pending[$0] != nil } ?? false }

    /// Layout snapshots only: an example run with every kind of message.
    func addPreviewRun() -> AgentRun {
        let run = AgentRun(folder: URL(fileURLWithPath: "/Users/you/Code/website"))
        run.messages = [
            .init(kind: .user, text: "Fix the failing tests and tell me what was wrong"),
            .init(kind: .tool, text: "Reading checkout.test.ts", detail: "Read"),
            .init(kind: .assistant, text: "The price test expects VAT included, but the helper returns it without. I'll fix the helper."),
            .init(kind: .approval, text: "Editing price.ts", detail: "src/lib/price.ts", decided: "Allowed"),
            .init(kind: .tool, text: "Editing price.ts", detail: "Edit"),
            .init(kind: .approval, text: "Running npm test", detail: "npm test", decided: "Allowed"),
            .init(kind: .assistant, text: "All **12 tests** pass now. The helper forgot to add VAT for Swedish orders."),
        ]
        run.state = .idle
        run.cost = 0.18
        runs.insert(run, at: 0)
        return run
    }
}
