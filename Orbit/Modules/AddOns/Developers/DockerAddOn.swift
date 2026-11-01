import SwiftUI

/// Docker containers: what's running, with Start, Stop and Restart.
@MainActor
@Observable
final class DockerAddOn: AddOnModule {
    let id = "addon.docker"
    let title = "Docker"
    let symbol = "shippingbox"
    let addOn = AddOnInfo(category: .developers, tier: .free,
                          summary: "Your Docker containers at a glance, with start, stop and restart.")

    enum Status: Equatable { case loading, notInstalled, daemonDown, failed(String), ready }

    private(set) var containers: [DockerContainer] = []
    private(set) var status: Status = .loading
    private(set) var busy: Set<String> = []
    private(set) var actionError: String?
    var visible = false
    /// The Home card is on screen (it keeps the list fresh too).
    var homeVisible = false
    private var loading = false
    private var timer: Timer?
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview { loadSample() }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.visible == true || self?.homeVisible == true { self?.refresh() } }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    static var dockerPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.docker/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard !ModuleRegistry.isPreview, !loading else { return }
        guard let docker = Self.dockerPath else { status = .notInstalled; return }
        loading = true
        Task {
            let out = await Task.detached { DevCommand.run(docker, ["ps", "-a", "--format", "{{json .}}"], timeout: 10) }.value
            loading = false
            guard let out else { status = .notInstalled; return }
            if out.ok {
                containers = DockerParsing.containers(out.stdout)
                status = .ready
            } else if out.timedOut || DockerParsing.isDaemonDown(out.stderr) {
                status = .daemonDown
            } else {
                status = .failed(DockerParsing.firstLine(out.stderr))
            }
        }
    }

    func perform(_ verb: String, on container: DockerContainer) {
        guard ["start", "stop", "restart"].contains(verb), let docker = Self.dockerPath, !busy.contains(container.id) else { return }
        busy.insert(container.id)
        actionError = nil
        let cid = container.id
        Task {
            let out = await Task.detached { DevCommand.run(docker, [verb, cid], timeout: 30) }.value
            busy.remove(cid)
            if out?.ok != true {
                actionError = "Couldn't \(verb) \(container.name): " + DockerParsing.firstLine(out?.stderr ?? "timed out")
            }
            refresh()
        }
    }

    var runningContainers: Int { containers.filter(\.isRunning).count }

    /// How Orbit rides its crate: happily while containers run, asleep when they're all stopped
    /// or Docker is off, wide-eyed when Docker is missing or fails.
    var orbitPose: (mood: OrbitView.Mood, motion: OrbitView.Motion, rocking: Bool) {
        switch status {
        case .loading: (.normal, .thinking, false)
        case .notInstalled: (.wide, .idle, false)
        case .daemonDown: (.closed, .sleep, false)
        case .failed: (.grumpy, .idle, false)
        case .ready: runningContainers > 0 ? (.happy, .idle, true) : (.closed, .sleep, false)
        }
    }

    var homeCard: AnyView? { AnyView(DockerHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(DockerPanel(module: self)) }

    private func loadSample() {
        containers = DockerParsing.containers("""
        {"ID":"a1b2c3d4e5f6","Names":"orbit-db","Image":"postgres:16","State":"running","Status":"Up 3 hours","Ports":"0.0.0.0:5432->5432/tcp, :::5432->5432/tcp"}
        {"ID":"b2c3d4e5f6a1","Names":"orbit-redis","Image":"redis:7-alpine","State":"running","Status":"Up 3 hours","Ports":"0.0.0.0:6379->6379/tcp"}
        {"ID":"c3d4e5f6a1b2","Names":"mailpit","Image":"axllent/mailpit","State":"running","Status":"Up 12 minutes","Ports":"0.0.0.0:1025->1025/tcp, 0.0.0.0:8025->8025/tcp"}
        {"ID":"d4e5f6a1b2c3","Names":"old-api","Image":"node:20","State":"exited","Status":"Exited (0) 2 days ago","Ports":""}
        """)
        busy = ["c3d4e5f6a1b2"]
        status = .ready
    }
}

// MARK: - Parsing (pure, tested)

struct DockerContainer: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: [String]
    var isRunning: Bool { state == "running" }
}

enum DockerParsing {
    private struct Line: Decodable {
        let ID: String
        let Names: String?
        let Image: String?
        let State: String?
        let Status: String?
        let Ports: String?
    }

    /// One JSON object per line, from `docker ps -a --format '{{json .}}'`.
    static func containers(_ text: String) -> [DockerContainer] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let l = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
            let status = l.Status ?? ""
            let state = l.State ?? (status.hasPrefix("Up") ? "running" : "exited")
            return DockerContainer(id: l.ID, name: l.Names ?? l.ID, image: l.Image ?? "", state: state.lowercased(),
                                   status: status, ports: ports(l.Ports ?? ""))
        }
        .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    /// "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp" → ["5432→5432"]; unpublished "6379/tcp" → ["6379"].
    static func ports(_ text: String) -> [String] {
        var seen: [String] = []
        for part in text.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            let label: String
            if let arrow = p.range(of: "->") {
                let host = p[..<arrow.lowerBound].split(separator: ":").last.map(String.init) ?? ""
                let inner = p[arrow.upperBound...].split(separator: "/").first.map(String.init) ?? ""
                label = "\(host)→\(inner)"
            } else {
                label = p.split(separator: "/").first.map(String.init) ?? p
            }
            if !seen.contains(label) { seen.append(label) }
        }
        return seen
    }

    static func isDaemonDown(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("cannot connect to the docker daemon") || s.contains("is the docker daemon running")
            || s.contains("docker.sock") || s.contains("error during connect")
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "unknown error" : String(line.prefix(160))
    }
}

// MARK: - Panel

private struct DockerPanel: View {
    let module: DockerAddOn

    var subtitle: String {
        guard module.status == .ready else { return "Containers" }
        let running = module.runningContainers
        return "\(running) running · \(module.containers.count - running) stopped"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: "shippingbox.fill", title: "Docker", subtitle: subtitle, tint: AddOnCategory.developers.tint)
                if module.status == .ready, !module.containers.isEmpty {
                    let pose = module.orbitPose
                    DevCrateOrbit(size: 46, mood: pose.mood, motion: pose.motion, rocking: pose.rocking)
                }
                DevIconButton(symbol: "arrow.clockwise", help: "Refresh") { module.refresh() }
            }
            if let error = module.actionError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Tokens.error).lineLimit(2)
            }
            switch module.status {
            case .loading:
                DevEmptyState(symbol: "shippingbox", title: "Looking for Docker…", message: "This takes a second.")
            case .notInstalled:
                DevEmptyState(symbol: "shippingbox", title: "Docker isn't installed",
                              message: "Install Docker Desktop, OrbStack or Colima, then come back here.",
                              art: AnyView(DevCrateOrbit(size: 72, mood: .wide, rocking: false)))
            case .daemonDown:
                VStack(spacing: 12) {
                    DevEmptyState(symbol: "moon.zzz.fill", title: "Docker isn't running",
                                  message: "Start Docker Desktop (or your Docker engine) and your containers show up here.",
                                  tint: Tokens.attention,
                                  art: AnyView(DevCrateOrbit(size: 72, mood: .closed, motion: .sleep, rocking: false)))
                        .frame(maxHeight: 190)
                    GlassPillButton(title: "Open Docker", symbol: "arrow.up.forward.app") {
                        DevActions.open("file:///Applications/Docker.app")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                DevEmptyState(symbol: "exclamationmark.triangle", title: "Docker said no", message: message, tint: Tokens.error)
            case .ready:
                if module.containers.isEmpty {
                    DevEmptyState(symbol: "shippingbox", title: "No containers",
                                  message: "Containers you create with docker run or compose show up here.",
                                  art: AnyView(DevCrateOrbit(size: 72, rocking: false)))
                } else {
                    NotchScroll {
                        VStack(spacing: 6) {
                            ForEach(module.containers) { c in row(c) }
                        }
                    }
                }
            }
        }
        .onAppear { module.visible = true; module.refresh() }
        .onDisappear { module.visible = false }
    }

    func row(_ c: DockerContainer) -> some View {
        HStack(spacing: 10) {
            Circle().fill(c.isRunning ? Tokens.live : Tokens.faint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(c.image).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.faint).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(c.status).font(.system(size: 11)).foregroundStyle(c.isRunning ? Tokens.live : Tokens.secondary).lineLimit(1)
                    ForEach(c.ports.prefix(3), id: \.self) { DevTag(text: $0) }
                }
            }
            Spacer(minLength: 6)
            if module.busy.contains(c.id) {
                Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                Text("Working…").font(.system(size: 11.5)).foregroundStyle(Tokens.secondary)
            } else if c.isRunning {
                DevIconButton(symbol: "arrow.clockwise", help: "Restart") { module.perform("restart", on: c) }
                GlassPillButton(title: "Stop", symbol: "stop.fill") { module.perform("stop", on: c) }
            } else {
                GlassPillButton(title: "Start", symbol: "play.fill") { module.perform("start", on: c) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassCard(16)
    }
}

/// Home: how many containers run, with the first few to start or stop in one click.
private struct DockerHomeCard: View {
    let module: DockerAddOn
    let open: () -> Void

    var body: some View {
        let pose = module.orbitPose
        NotchCard {
            HStack(spacing: 12) {
                DevCrateOrbit(size: 50, mood: pose.mood, motion: pose.motion, rocking: pose.rocking)
                VStack(alignment: .leading, spacing: 4) {
                    CardLabel("Docker")
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if module.status == .ready, !module.containers.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(module.containers.prefix(3)) { chip($0) }
                        }
                    } else {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(minHeight: 78)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onAppear { module.homeVisible = true; module.refresh() }
        .onDisappear { module.homeVisible = false }
    }

    private var title: String {
        switch module.status {
        case .loading: "Looking for Docker…"
        case .notInstalled: "Docker isn't installed"
        case .daemonDown: "Docker isn't running"
        case .failed: "Docker said no"
        case .ready:
            module.containers.isEmpty ? "No containers"
                : "\(module.runningContainers) running · \(module.containers.count - module.runningContainers) stopped"
        }
    }

    private var detail: String {
        switch module.status {
        case .daemonDown: "Start your Docker engine to see containers"
        case .failed(let message): message
        default: "Containers show up here"
        }
    }

    private func chip(_ c: DockerContainer) -> some View {
        let busy = module.busy.contains(c.id)
        return HStack(spacing: 5) {
            Circle().fill(c.isRunning ? Tokens.live : Tokens.faint).frame(width: 6, height: 6)
            Text(c.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 76, alignment: .leading)
            Button { module.perform(c.isRunning ? "stop" : "start", on: c) } label: {
                Image(systemName: busy ? "hourglass" : (c.isRunning ? "stop.fill" : "play.fill"))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(busy ? Tokens.secondary : .white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Tokens.surface2))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(busy ? "Working…" : (c.isRunning ? "Stop \(c.name)" : "Start \(c.name)"))
        }
        .padding(.leading, 8).padding(.trailing, 3).padding(.vertical, 3)
        .background(Tokens.surface, in: Capsule())
    }
}
