import AppKit
import SwiftUI

/// What Ask can do in the rest of the app. The registry wires these to the other modules.
struct AskActions {
    var startTimer: @MainActor (_ minutes: Int) -> Void
    var addTask: @MainActor (_ text: String) -> Void
    var addNote: @MainActor (_ text: String) -> Void
    var playPauseMusic: @MainActor () -> Void
    var nextTrack: @MainActor () -> Void
    var joinNextMeeting: @MainActor () -> Void
    /// Title of the next joinable meeting, shown in the suggestion. Nil hides "Join".
    var nextMeetingTitle: @MainActor () -> String?
    var openTab: @MainActor (_ id: String) -> Void
    var searchWeb: @MainActor (_ query: String) -> Void
    var openApp: @MainActor (_ name: String) -> Bool

    init(startTimer: @escaping @MainActor (Int) -> Void,
         addTask: @escaping @MainActor (String) -> Void,
         addNote: @escaping @MainActor (String) -> Void,
         playPauseMusic: @escaping @MainActor () -> Void,
         nextTrack: @escaping @MainActor () -> Void,
         joinNextMeeting: @escaping @MainActor () -> Void,
         nextMeetingTitle: @escaping @MainActor () -> String? = { nil },
         openTab: @escaping @MainActor (String) -> Void,
         searchWeb: @escaping @MainActor (String) -> Void = AskActions.googleSearch,
         openApp: @escaping @MainActor (String) -> Bool = AskActions.launchApp) {
        self.startTimer = startTimer
        self.addTask = addTask
        self.addNote = addNote
        self.playPauseMusic = playPauseMusic
        self.nextTrack = nextTrack
        self.joinNextMeeting = joinNextMeeting
        self.nextMeetingTitle = nextMeetingTitle
        self.openTab = openTab
        self.searchWeb = searchWeb
        self.openApp = openApp
    }

    @MainActor static func googleSearch(_ query: String) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Opens an app by name from /Applications (and a few other usual places). Case-insensitive.
    @MainActor static func launchApp(_ name: String) -> Bool {
        guard let url = findApp(name) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @MainActor static func findApp(_ name: String) -> URL? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let exact = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            if fm.fileExists(atPath: exact.path) { return exact }
        }
        var prefix: URL?
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let base = String(item.dropLast(4)).lowercased()
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if base == wanted { return url }
                if prefix == nil, base.hasPrefix(wanted) { prefix = url }
            }
        }
        return prefix
    }
}

/// One row in the Ask list.
struct AskSuggestion: Identifiable {
    let id: String
    let symbol: String
    let title: String
    /// Small grey tag on the right, e.g. "Action", "To-dos".
    let kind: String
    let run: @MainActor () -> Void
}

/// A command bar: type what you want, pick a suggestion, carry on.
@MainActor
@Observable
final class AskModule: NotchModule {
    let id = "ask"
    let title = "Ask"
    let symbol = "magnifyingglass"

    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    /// Short confirmation after running something, e.g. "Added to Notes".
    private(set) var toast: String?

    // Claude answer
    private(set) var claudePrompt: String?
    private(set) var claudeAnswer: String?
    private(set) var claudeError: String?
    private(set) var isThinking = false
    private var claudeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private let actions: AskActions
    /// Claude-powered assistant; used when an API key is set.
    var smart: SmartAssistant?

    init(actions: AskActions) {
        self.actions = actions
    }

    var suggestions: [AskSuggestion] { Self.suggestions(for: query, actions: actions, ask: self) }

    // MARK: Running

    func runSelected() {
        let list = suggestions
        guard !list.isEmpty else { return }
        list[min(max(0, selection), list.count - 1)].run()
    }

    func addSelectedToNotes() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.addNote(text)
        done("Added to Notes")
    }

    func move(_ delta: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }

    /// Esc: clears the field (or the answer). Returns false when there was nothing to clear.
    func clear() -> Bool {
        if !query.isEmpty { query = ""; return true }
        if let smart, !smart.turns.isEmpty || smart.busy { smart.reset(); return true }
        if claudeAnswer != nil || claudeError != nil || isThinking { dismissAnswer(); return true }
        return false
    }

    fileprivate func done(_ message: String, clearQuery: Bool = true) {
        if clearQuery { query = "" }
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissAnswer() {
        claudeTask?.cancel()
        claudeTask = nil
        isThinking = false
        claudePrompt = nil
        claudeAnswer = nil
        claudeError = nil
    }

    /// Runs `claude -p` from the login shell's PATH, in the background, for up to 60 s.
    func askClaude(_ prompt: String) {
        dismissAnswer()
        claudePrompt = prompt
        isThinking = true
        query = ""
        claudeTask = Task { [weak self] in
            let result = await ClaudeRunner.run(prompt: prompt, timeout: 60)
            guard !Task.isCancelled, let self else { return }
            self.isThinking = false
            switch result {
            case .success(let text): self.claudeAnswer = text
            case .failure(let error): self.claudeError = error.message
            }
        }
    }

    func copyAnswer() {
        guard let claudeAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeAnswer, forType: .string)
        done("Copied", clearQuery: false)
    }

    func stop() { claudeTask?.cancel() }

    var panel: AnyView { AnyView(AskPanel(module: self)) }

    // MARK: Parsing

    static let tabs: [(id: String, title: String, symbol: String)] = [
        ("music", "Music", "music.note"), ("meetings", "Meetings", "calendar"),
        ("tasks", "To-dos", "checklist"), ("focus", "Focus", "timer"), ("notes", "Notes", "note.text"),
        ("shelf", "Shelf", "tray"), ("agents", "Agents", "sparkles"),
        ("prompter", "Prompter", "text.alignleft"), ("mirror", "Mirror", "person.crop.square"),
    ]

    /// Rule-based ranking: specific actions first, then the catch-alls.
    static func suggestions(for raw: String, actions: AskActions, ask: AskModule) -> [AskSuggestion] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        var out: [AskSuggestion] = []

        // Smart Ask understands anything and acts on it, so it comes first when a Claude key is set.
        if let smart = ask.smart, smart.isConfigured {
            out.append(AskSuggestion(id: "smart", symbol: "sparkles", title: "Ask Orbit “\(q)”", kind: "Smart") {
                smart.send(q); ask.query = ""
            })
        }

        // Timer / focus
        if let minutes = timerMinutes(lower) {
            out.append(AskSuggestion(id: "timer", symbol: "timer", title: "Start a \(minutes)-minute timer", kind: "Action") {
                actions.startTimer(minutes); ask.done("Timer started · \(minutes) min")
            })
        }

        // Music
        let first = words.first ?? ""
        if ["play", "pause", "resume", "stop", "toggle"].contains(first) || lower == "music" || lower == "play/pause" {
            out.append(AskSuggestion(id: "playpause", symbol: "playpause.fill", title: "Play / pause music", kind: "Action") {
                actions.playPauseMusic(); ask.done("Play / pause")
            })
        }
        if ["next", "skip"].contains(first) || lower.contains("next song") || lower.contains("next track") {
            out.append(AskSuggestion(id: "next", symbol: "forward.fill", title: "Next track", kind: "Action") {
                actions.nextTrack(); ask.done("Next track")
            })
        }

        // Meetings
        if words.contains(where: { ["join", "meeting", "meet", "call", "zoom"].contains($0) }) {
            let title = actions.nextMeetingTitle()
            out.append(AskSuggestion(id: "join", symbol: "video.fill",
                                     title: title.map { "Join \($0)" } ?? "Join next meeting", kind: "Action") {
                actions.joinNextMeeting(); ask.done("Joining…")
            })
        }

        // Open app / tab
        if first == "open" || first == "launch" {
            let name = q.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if !name.isEmpty {
                if let tab = tabs.first(where: { $0.title.lowercased() == name.lowercased() || $0.id == name.lowercased() }) {
                    out.append(AskSuggestion(id: "tab-\(tab.id)", symbol: tab.symbol, title: "Open \(tab.title)", kind: "Orbit") {
                        actions.openTab(tab.id); ask.done("", clearQuery: true)
                    })
                }
                let appName = findAppName(name) ?? name
                out.append(AskSuggestion(id: "app", symbol: "app.dashed", title: "Open \(appName)", kind: "App") {
                    if actions.openApp(appName) { ask.done("Opening \(appName)") } else { ask.done("Couldn't find \(appName)", clearQuery: false) }
                })
            }
        } else if let tab = tabs.first(where: { $0.title.lowercased() == lower || $0.id == lower }) {
            out.append(AskSuggestion(id: "tab-\(tab.id)", symbol: tab.symbol, title: "Open \(tab.title)", kind: "Orbit") {
                actions.openTab(tab.id); ask.done("", clearQuery: true)
            })
        }

        // Explicit note / task prefixes put that one first among the catch-alls.
        let notePrefix = stripPrefix(q, ["note:", "note ", "notes "])
        let taskPrefix = stripPrefix(q, ["todo:", "todo ", "to-do ", "task:", "task ", "remind me to ", "remind "])
        let taskText = taskPrefix ?? q
        let noteText = notePrefix ?? q

        let addTask = AskSuggestion(id: "task", symbol: "checklist", title: "Add to To-dos “\(taskText)”", kind: "To-dos") {
            actions.addTask(taskText); ask.done("Added to To-dos")
        }
        let addNote = AskSuggestion(id: "note", symbol: "note.text", title: "Add to Notes “\(noteText)”", kind: "Notes") {
            actions.addNote(noteText); ask.done("Added to Notes")
        }
        if notePrefix != nil { out += [addNote, addTask] } else { out += [addTask, addNote] }

        out.append(AskSuggestion(id: "web", symbol: "globe", title: "Search the web for “\(q)”", kind: "Web") {
            actions.searchWeb(q); ask.done("Searching…")
        })
        out.append(AskSuggestion(id: "claude", symbol: "sparkles", title: "Ask Claude “\(q)”", kind: "Claude") {
            ask.askClaude(q)
        })
        return out
    }

    /// "timer 10 min", "10 min timer", "focus 25", "25m", "1 hour timer" → minutes.
    static func timerMinutes(_ s: String) -> Int? {
        let hasKeyword = s.contains("timer") || s.contains("focus")
        guard let match = s.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)?\b/) else {
            return nil
        }
        let number = Double(match.1.replacingOccurrences(of: ",", with: ".")) ?? 0
        let unit = match.2.map(String.init) ?? ""
        guard hasKeyword || !unit.isEmpty, number > 0 else { return nil }
        // A bare "10 m" without timer/focus is still a timer only if the whole text is just that.
        if !hasKeyword && s.split(separator: " ").count > 2 { return nil }
        let minutes: Double
        switch unit.first {
        case "h": minutes = number * 60
        case "s": minutes = max(1, number / 60)
        default: minutes = number
        }
        let m = Int(minutes.rounded())
        return (1...600).contains(m) ? m : nil
    }

    private static func stripPrefix(_ s: String, _ prefixes: [String]) -> String? {
        let lower = s.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            let rest = s.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func findAppName(_ name: String) -> String? {
        AskActions.findApp(name)?.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Claude

enum ClaudeRunner {
    struct Failure: Error { let message: String }

    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    static func run(prompt: String, timeout: TimeInterval) async -> Result<String, Failure> {
        let box = Box()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Prompt goes through the environment so no quoting is needed. `exec` so terminate() hits claude itself.
        p.arguments = ["-lc", "command -v claude >/dev/null 2>&1 || exit 127; exec claude -p \"$ORBIT_PROMPT\""]
        var env = ProcessInfo.processInfo.environment
        env["ORBIT_PROMPT"] = prompt
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> Result<String, Failure> in
                do { try box.process.run() } catch { return .failure(Failure(message: "Couldn't start zsh: \(error.localizedDescription)")) }
                let timer = Task.detached {
                    try? await Task.sleep(for: .seconds(timeout))
                    if box.process.isRunning { box.process.terminate() }
                }
                let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                box.process.waitUntilExit()
                timer.cancel()
                let errText = String(data: await errData.value, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = box.process.terminationStatus
                if box.process.terminationReason == .uncaughtSignal {
                    return .failure(Failure(message: "Claude took longer than \(Int(timeout)) s."))
                }
                if status == 127 { return .failure(Failure(message: "Couldn't find `claude` on your PATH.")) }
                if status != 0 {
                    return .failure(Failure(message: errText.isEmpty ? "Claude exited with code \(status)." : String(errText.prefix(400))))
                }
                return .success(text.isEmpty ? "(No answer)" : text)
            }.value
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}

// MARK: - Panel

struct AskPanel: View {
    let module: AskModule
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var module = module
        let list = module.suggestions
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Tokens.secondary)
                TextField("Ask, or type a command — “timer 10 min”, “open Safari”…", text: $module.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                if let toast = module.toast, !toast.isEmpty {
                    Text(toast).font(.system(size: 11)).foregroundStyle(Tokens.live).transition(.opacity)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let smart = module.smart, !smart.turns.isEmpty, module.query.isEmpty {
                SmartConversation(smart: smart)
            } else if module.claudePrompt != nil && module.query.isEmpty {
                AskAnswer(module: module)
            } else if list.isEmpty {
                Text(module.smart?.isConfigured == true
                     ? "Ask anything or tell Orbit what to do: “move Skapa offert to Monday 9:00”, “what do I have today?”, “start 50 min focus”."
                     : "Start a timer, add a to-do or note, control music, join your next meeting, open an app — or ask Claude.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.faint)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                                AskRow(suggestion: s, selected: i == module.selection)
                                    .id(s.id)
                                    .onTapGesture { module.selection = i; s.run() }
                                    .onHover { if $0 { module.selection = i } }
                            }
                        }
                    }
                    .onChange(of: module.selection) { _, i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }
            }

            HStack(spacing: 12) {
                hint("↩", "open"); hint("↑↓", "choose"); hint("⌘↩", "add to Notes"); hint("esc", "clear")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .modifier(KeyDownMonitor { e in
            switch e.keyCode {
            case 126: module.move(-1); return true
            case 125: module.move(1); return true
            case 36, 76:
                if e.modifierFlags.contains(.command) { module.addSelectedToNotes() } else { module.runSelected() }
                return true
            case 53: return module.clear() // nothing to clear → let Esc close the notch
            default: return false
            }
        })
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.surface2))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(Tokens.faint)
    }
}

private struct AskRow: View {
    let suggestion: AskSuggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.white.opacity(0.15) : Tokens.surface2))
            Text(suggestion.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(suggestion.kind).font(.system(size: 10.5)).foregroundStyle(Tokens.faint)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Tokens.surface2 : .clear))
        .contentShape(Rectangle())
    }
}

private struct AskAnswer: View {
    let module: AskModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                Text(module.claudePrompt ?? "").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer()
                if module.claudeAnswer != nil {
                    IconButton(symbol: "doc.on.doc", size: 11) { module.copyAnswer() }.help("Copy")
                }
                IconButton(symbol: "xmark", size: 10) { module.dismissAnswer() }
            }
            ScrollView(.vertical) {
                Group {
                    if module.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").foregroundStyle(Tokens.secondary)
                        }
                    } else if let error = module.claudeError {
                        Text(error).foregroundStyle(Tokens.error)
                    } else if let answer = module.claudeAnswer {
                        Text(LocalizedStringKey(answer)).textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke))
    }
}

// MARK: - Keys

/// Listens to key presses while the view is on screen. Return true from the handler to swallow the key.
struct KeyDownMonitor: ViewModifier {
    let handler: @MainActor (NSEvent) -> Bool
    @State private var token: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil else { return }
                let handler = handler
                token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    MainActor.assumeIsolated { handler(e) } ? nil : e
                }
            }
            .onDisappear {
                if let token { NSEvent.removeMonitor(token) }
                token = nil
            }
    }
}
