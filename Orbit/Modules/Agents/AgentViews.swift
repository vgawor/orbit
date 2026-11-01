import AppKit
import SwiftUI
import OrbitKit

/// An Orbit for one agent run: a colour per project folder, acting out what Claude is doing.
struct AgentOrbit: View {
    let run: AgentRun
    var size: CGFloat = 30

    var body: some View {
        let state: AgentsModule.Session.State
        switch run.state {
        case .starting, .working: state = .working
        case .waiting: state = .needsInput
        case .idle, .stopped, .failed: state = .done
        }
        if case .failed = run.state {
            return AnyView(OrbitView(size: size, mood: .grumpy, motion: .still, colors: OrbitView.agentColors(run.name)))
        }
        return AnyView(OrbitView.agent(project: run.name, state: state, size: size))
    }
}

extension OrbitView {
    /// The colour an agent gets for a project name (same as `agent(project:state:size:)`).
    static func agentColors(_ project: String) -> Appearance.Companion {
        let others = Appearance.companions.filter { $0.id != Appearance.shared.companionID }
        return others[abs(project.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % max(others.count, 1)]
    }
}

// MARK: - New agent task

/// Pick a project folder and say what to do. Claude Code does the work; Orbit asks before changes.
struct NewAgentTaskView: View {
    let module: AgentsModule
    @State private var error: String?
    @FocusState private var focused: Bool

    private var runner: AgentRunner { module.runner }

    var body: some View {
        @Bindable var module = module
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                OrbitView(size: 40, mood: .normal, motion: .thinking)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New agent task").font(.system(size: 15, weight: .semibold))
                    Text("Claude Code does the work in your project. Orbit asks you first.")
                        .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Project folder").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                HStack(spacing: 6) {
                    ForEach(runner.recentFolders.prefix(3), id: \.self) { path in
                        folderChip(path)
                    }
                    if let draft = module.draftFolder, !runner.recentFolders.prefix(3).contains(draft) {
                        folderChip(draft)
                    }
                    Button(action: chooseFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 11))
                            Text("Choose…").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .glassSurface(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                if let folder = module.draftFolder {
                    Text(folder).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.faint).lineLimit(1).truncationMode(.head)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What should it do?").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                TextField("Fix the failing tests and explain what was wrong", text: $module.draftPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...6)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tokens.stroke)))
                    .focused($focused)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Tokens.attention).padding(.top, 1)
                Text("Reading your code is allowed. Editing files and running commands each need your OK, in the notch. Anything you don't answer is denied.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            }

            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Tokens.error)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                GlassPillButton(title: "Cancel") { module.selection = "overview" }
                PillButton(title: "Start agent", fill: canStart ? .white : Tokens.surface2, action: start)
                    .disabled(!canStart)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(24)
        .onAppear {
            if module.draftFolder == nil { module.draftFolder = runner.recentFolders.first }
            focused = true
        }
    }

    private var canStart: Bool {
        module.draftFolder != nil && !module.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func folderChip(_ path: String) -> some View {
        let on = module.draftFolder == path
        return Button { module.draftFolder = path } label: {
            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.08)))
                .foregroundStyle(on ? Color.black : .white)
                .frame(maxWidth: 130)
        }
        .buttonStyle(.plain)
        .help(path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose the project folder the agent works in"
        NSApp.activate()
        let module = module
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { module.draftFolder = url.path }
        }
    }

    private func start() {
        guard let folder = module.draftFolder else { return }
        let prompt = module.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch runner.start(in: URL(fileURLWithPath: folder), prompt: prompt) {
        case .success(let run):
            module.draftPrompt = ""
            error = nil
            module.selection = run.id
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

// MARK: - Chat with a running agent

struct AgentChatView: View {
    let run: AgentRun
    let module: AgentsModule
    @State private var text = ""

    private var runner: AgentRunner { module.runner }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.vertical, 10)
            Divider().overlay(Tokens.stroke)
            ScrollViewReader { proxy in
                NotchScroll {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(run.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if run.state == .starting || run.state == .working {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(run.state == .starting ? "Starting Claude Code…" : "Working…")
                                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: run.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(run.messages.last?.id, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(run.messages.last?.id, anchor: .bottom) }
            }
            composer.padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentOrbit(run: run, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(.system(size: 14, weight: .semibold))
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer()
            if run.cost > 0 {
                Text(run.cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Tokens.faint)
                    .help("What this task has cost on your Claude plan or API key so far")
            }
            if run.isBusy {
                GlassPillButton(title: "Stop", symbol: "stop.fill") { runner.stop(run) }
            } else {
                Button { runner.remove(run); module.selection = "overview" } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26).glassSurface(Circle(), interactive: true)
                }
                .buttonStyle(.plain).help("Remove from the list")
            }
        }
    }

    private var statusText: String {
        switch run.state {
        case .starting: "Starting · \(run.folder.path)"
        case .working: "Working"
        case .waiting: "Waiting for your OK"
        case .idle: "Done · send a message to continue"
        case .failed(let why): why
        case .stopped: "Stopped · send a message to continue"
        }
    }

    private var statusColor: Color {
        switch run.state {
        case .waiting: Tokens.attention
        case .failed: Tokens.error
        case .working, .starting: Tokens.live
        default: Tokens.secondary
        }
    }

    @ViewBuilder private func bubble(_ m: AgentRun.Message) -> some View {
        switch m.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(m.text).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5,
                                                       topTrailingRadius: 16, style: .continuous).fill(Color.white.opacity(0.17)))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                AgentOrbit(run: run, size: 22).padding(.top, 1)
                Text(LocalizedStringKey(m.text)).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: icon(for: m.detail)).font(.system(size: 9.5, weight: .semibold))
                Text(m.text).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(Tokens.secondary)
            .padding(.leading, 30)
        case .note where m.detail == "signin":
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(Tokens.attention)
                    Text(AgentRun.signInMessage).font(.system(size: 13, weight: .semibold))
                }
                Text("Its login has expired. In Terminal, run **claude**, type **/login** and follow the steps. Then send a message here to try again.")
                    .font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Open Terminal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                    GlassPillButton(title: "Copy “claude”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude", forType: .string)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tokens.attention.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.attention.opacity(0.4)))
            .padding(.leading, 30)
        case .note:
            Text(m.text).font(.system(size: 11.5)).foregroundStyle(Tokens.faint).padding(.leading, 30)
        case .approval:
            approvalCard(m)
        }
    }

    private func approvalCard(_ m: AgentRun.Message) -> some View {
        let waiting = runner.isPending(m.approvalID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Tokens.attention)
                Text("Allow? \(m.text)").font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            if let detail = m.detail {
                Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.secondary)
                    .lineLimit(4).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            }
            if waiting, let id = m.approvalID {
                HStack(spacing: 8) {
                    GlassPillButton(title: "Deny") { runner.decide(id, .deny("Denied in Orbit"), label: "Denied") }
                    PillButton(title: "Allow") { runner.decide(id, .allow, label: "Allowed") }
                }
            } else if let decided = m.decided {
                Text(decided).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(decided == "Allowed" ? Tokens.live : Tokens.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tokens.attention.opacity(waiting ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Tokens.attention.opacity(waiting ? 0.5 : 0.15)))
        .padding(.leading, 30)
    }

    private func icon(for tool: String?) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        default: "sparkle"
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(run.isBusy ? "Wait for this step to finish…" : "Message \(run.name)…", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13))
                .lineLimit(1...4)
                .disabled(run.isBusy)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend ? Color.white : Color.white.opacity(0.15)))
                    .foregroundStyle(canSend ? Color.black : Tokens.faint)
            }
            .buttonStyle(.plain).disabled(!canSend)
        }
        .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.25)).overlay(Capsule().stroke(Tokens.stroke)))
    }

    private var canSend: Bool { !run.isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        runner.send(text.trimmingCharacters(in: .whitespacesAndNewlines), to: run)
        text = ""
    }
}

// MARK: - Orbit (Smart Ask) as a conversation

/// Smart Ask inside the Agents screen: the same conversation as the Ask tab.
struct OrbitChatPane: View {
    let smart: SmartAssistant
    @State private var text = ""

    private let suggestions = ["What's my day?", "Prep me for my next meeting", "Start 25 min focus", "What's overdue?"]

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if !smart.isConfigured {
                    VStack(spacing: 10) {
                        OrbitView(size: 56, mood: .normal, motion: .idle)
                        Text("Add your Claude API key in Settings → Accounts to chat with Orbit.")
                            .font(.system(size: 12.5)).foregroundStyle(Tokens.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if smart.turns.isEmpty && !smart.busy {
                    VStack(spacing: 12) {
                        OrbitView(size: 64, mood: .normal, motion: .idle)
                        Text("Ask Orbit anything").font(.system(size: 15, weight: .semibold))
                        Text("Tasks, meetings, focus and HubSpot. Orbit asks before changing anything.")
                            .font(.system(size: 12)).foregroundStyle(Tokens.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            ForEach(suggestions.prefix(3), id: \.self) { s in
                                GlassPillButton(title: s) { smart.send(s) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SmartConversation(smart: smart)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)

            HStack(spacing: 8) {
                TextField(smart.busy ? "Orbit is thinking…" : "Message Orbit…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .disabled(!smart.isConfigured)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Color.white : Color.white.opacity(0.15)))
                        .foregroundStyle(canSend ? Color.black : Tokens.faint)
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.25)).overlay(Capsule().stroke(Tokens.stroke)))
            .padding([.horizontal, .bottom], 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(24)
    }

    private var canSend: Bool {
        smart.isConfigured && !smart.busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        smart.send(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
    }
}
