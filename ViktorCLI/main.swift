import Foundation
import ViktorKit

// viktor — talk to the Orbit notch app from your terminal and scripts.

let usage = """
viktor — send updates and questions to the Viktor notch app

USAGE
  viktor status                                   Check that Viktor is running
  viktor send --title T [--id ID] [--subtitle S] [--progress 0.5]
              [--status active|waiting|success|error] [--ttl SECONDS]
                                                  Show or update an item (reuse --id to update)
  viktor run [--title T] -- <command> [args…]     Run a command and show its progress and result
  viktor ask "Question?" --actions Yes,No [--timeout 60]
                                                  Ask with buttons; prints the choice (exit 1 if unanswered)
  viktor ls [--json]                              List items
  viktor rm ID                                    Remove an item
  viktor hook install claude [--settings PATH]    Show Claude Code activity in the notch
  viktor hook uninstall claude [--settings PATH]  Stop showing it
  viktor hook claude                              (used by Claude Code itself; reads the event on stdin)
  viktor hook permission                          (used by agents Orbit starts: asks you Allow/Deny)

The app must be running. The API listens on \(APIConfig.baseURL.absoluteString) and needs the token in
\(APIConfig.tokenURL.path).
"""

// MARK: - Helpers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("viktor: \(message)\n".utf8))
    exit(code)
}

/// Reads `--name value` pairs and plain arguments.
struct Args {
    var flags: [String: String] = [:]
    var bools: Set<String> = []
    var positional: [String] = []
    var passthrough: [String] = []

    init(_ raw: [String], booleans: Set<String> = []) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a == "--" { passthrough = Array(raw[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if booleans.contains(name) { bools.insert(name) }
                else if i + 1 < raw.count { flags[name] = raw[i + 1]; i += 1 }
                else { fail("--\(name) needs a value") }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

enum Client {
    struct HTTPError: Error { let status: Int; let message: String }

    /// Sends a request to the app. `wait` is how long to wait for an answer.
    static func request(_ method: String, _ path: String, body: Data? = nil, wait: TimeInterval = 10) async throws -> (Int, Data) {
        guard let token = APIConfig.readToken() else {
            throw HTTPError(status: 0, message: "Viktor isn't set up yet. Open the Viktor app once.")
        }
        var req = URLRequest(url: APIConfig.baseURL.appendingPathComponent(path), timeoutInterval: wait)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw HTTPError(status: 0, message: "Can't reach Viktor. Is the app running?")
        }
    }

    static func errorText(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func send(_ item: APIItem) async throws -> APIItem {
        let (status, data) = try await request("POST", "v1/items", body: try APIJSON.encoder.encode(item))
        guard status == 200 else { throw HTTPError(status: status, message: errorText(data)) }
        return try APIJSON.decoder.decode(APIItem.self, from: data)
    }
}

func run(_ body: () async throws -> Void) async {
    do { try await body() } catch let e as Client.HTTPError {
        fail(e.message)
    } catch {
        fail(error.localizedDescription)
    }
}

// MARK: - Commands

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
argv.removeFirst()

switch command {
case "help", "-h", "--help":
    print(usage)

case "status":
    await run {
        let (status, data) = try await Client.request("GET", "v1/status", wait: 3)
        guard status == 200, let s = try? APIJSON.decoder.decode(StatusResponse.self, from: data) else {
            fail(status == 401 ? "The token was rejected. Restart Viktor." : Client.errorText(data))
        }
        print("Viktor \(s.version) is running · \(s.items) item(s)")
    }

case "send":
    let a = Args(argv)
    guard let title = a.flags["title"] ?? a.positional.first else { fail("send needs --title") }
    var item = APIItem(id: a.flags["id"] ?? UUID().uuidString, title: title, source: "terminal")
    item.subtitle = a.flags["subtitle"]
    item.progress = a.flags["progress"].flatMap(Double.init).map { min(max($0, 0), 1) }
    if let s = a.flags["status"] {
        guard let st = APIItem.Status(rawValue: s) else { fail("--status must be active, waiting, success or error") }
        item.status = st
    }
    item.ttl = a.flags["ttl"].flatMap(Double.init)
    await run {
        let saved = try await Client.send(item)
        print(saved.id)
    }

case "run":
    let a = Args(argv)
    guard !a.passthrough.isEmpty else { fail("usage: viktor run [--title T] -- <command> [args…]") }
    let commandLine = a.passthrough.joined(separator: " ")
    let id = a.flags["id"] ?? "run-\(UUID().uuidString.prefix(8))"
    let title = a.flags["title"] ?? a.passthrough[0]
    let started = Date()
    // Best effort: if Orbit isn't running, still run the command.
    _ = try? await Client.send(APIItem(id: id, title: title, subtitle: commandLine, status: .active, source: "terminal"))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = a.passthrough
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    signal(SIGINT, SIG_IGN) // let Ctrl-C reach the child; we report how it ended
    do { try process.run() } catch { fail("couldn't start \(a.passthrough[0]): \(error.localizedDescription)", code: 127) }
    process.waitUntilExit()
    let code = process.terminationStatus
    let seconds = Int(Date().timeIntervalSince(started).rounded())
    let ok = code == 0
    _ = try? await Client.send(APIItem(id: id, title: title,
                                       subtitle: ok ? "Done in \(seconds) s" : "Exit code \(code) after \(seconds) s",
                                       progress: 1, status: ok ? .success : .error, ttl: 60, source: "terminal"))
    exit(code)

case "ask":
    let a = Args(argv)
    guard let question = a.positional.first ?? a.flags["title"] else { fail("usage: viktor ask \"Question?\" --actions Yes,No") }
    let actions = (a.flags["actions"] ?? "OK").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let timeout = a.flags["timeout"].flatMap(Double.init) ?? 60
    let ask = AskRequest(title: question, subtitle: a.flags["subtitle"], actions: actions, timeout: timeout)
    await run {
        let (status, data) = try await Client.request("POST", "v1/ask", body: try APIJSON.encoder.encode(ask), wait: timeout + 10)
        let answer = try? APIJSON.decoder.decode(AskResponse.self, from: data)
        guard status == 200 || status == 408 else { fail(Client.errorText(data)) }
        if let choice = answer?.choice { print(choice); exit(0) }
        FileHandle.standardError.write(Data("viktor: no answer\n".utf8))
        exit(1)
    }

case "ls":
    let a = Args(argv, booleans: ["json"])
    await run {
        let (status, data) = try await Client.request("GET", "v1/items")
        guard status == 200 else { fail(Client.errorText(data)) }
        if a.bools.contains("json") { print(String(decoding: data, as: UTF8.self)); return }
        let items = try APIJSON.decoder.decode([APIItem].self, from: data)
        if items.isEmpty { print("No items."); return }
        for i in items {
            let progress = i.progress.map { " \(Int($0 * 100))%" } ?? ""
            print("\(i.id)\t\(i.status.rawValue)\(progress)\t\(i.title)")
        }
    }

case "rm":
    guard let id = argv.first else { fail("usage: viktor rm ID") }
    await run {
        let path = "v1/items/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        let (status, data) = try await Client.request("DELETE", path)
        guard status == 200 else { fail(Client.errorText(data)) }
        print("Removed \(id)")
    }

case "hook":
    let a = Args(argv, booleans: ["terminal"])
    let settings = a.flags["settings"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ClaudeHookInstaller.defaultSettingsURL
    switch (a.positional.first, a.positional.dropFirst().first) {
    case ("claude", nil):
        // Called by Claude Code on every event. Never fail or slow Claude down.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        _ = try? await Client.request("POST", "v1/hooks/claude", body: input, wait: 2)
        exit(0)
    case ("permission", nil) where a.bools.contains("terminal"):
        // Global hook for Claude Code sessions in your terminal: ask in the notch first.
        // No answer, "In terminal", or Orbit not running: print nothing, so Claude asks in the terminal as usual.
        if ProcessInfo.processInfo.environment[AgentPermission.runEnv] != nil { exit(0) } // Orbit's own runs have their own hook
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var event = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        event["terminal"] = true
        let body = (try? JSONSerialization.data(withJSONObject: event)) ?? input
        if let (status, data) = try? await Client.request("POST", "v1/agents/permission", body: body,
                                                          wait: TimeInterval(ClaudeHookInstaller.permissionTimeout - 10)),
           status == 200, let d = try? JSONDecoder().decode(AgentPermission.Decision.self, from: data),
           d.behavior == "allow" || d.behavior == "deny" {
            FileHandle.standardOutput.write(AgentPermission.hookOutput(d))
        }
        exit(0)
    case ("permission", nil):
        // Called by Claude Code (PermissionRequest hook) in sessions Orbit started.
        // Asks the app and prints Allow or Deny. If anything goes wrong, the answer is Deny.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var event = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        event["orbit_run_id"] = ProcessInfo.processInfo.environment[AgentPermission.runEnv] ?? ""
        let body = (try? JSONSerialization.data(withJSONObject: event)) ?? input
        var decision = AgentPermission.Decision.deny("Orbit isn't running, so nothing was approved.")
        if let (status, data) = try? await Client.request("POST", "v1/agents/permission", body: body,
                                                          wait: TimeInterval(AgentPermission.hookTimeout - 20)),
           status == 200, let d = try? JSONDecoder().decode(AgentPermission.Decision.self, from: data) {
            decision = d
        }
        FileHandle.standardOutput.write(AgentPermission.hookOutput(decision))
        exit(0)
    case ("install", "claude"):
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let cli = a.flags["cli"] ?? (me.hasPrefix("/") ? me : FileManager.default.currentDirectoryPath + "/" + me)
        do {
            try ClaudeHookInstaller.install(cliPath: cli, at: settings)
            print("Installed Viktor hooks in \(settings.path)")
            print("Restart your Claude Code sessions to pick them up.")
        } catch { fail(error.localizedDescription) }
    case ("uninstall", "claude"):
        do {
            try ClaudeHookInstaller.uninstall(at: settings)
            print("Removed Viktor hooks from \(settings.path)")
        } catch { fail(error.localizedDescription) }
    default:
        fail("usage: viktor hook install claude | viktor hook uninstall claude")
    }

default:
    fail("unknown command \"\(command)\". Run viktor help.")
}
