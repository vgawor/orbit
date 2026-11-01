import Darwin
import SwiftUI

/// Which processes are listening on TCP ports, with Open and Stop.
@MainActor
@Observable
final class PortsAddOn: AddOnModule {
    let id = "addon.ports"
    let title = "Ports"
    let symbol = "point.3.connected.trianglepath.dotted"
    let addOn = AddOnInfo(category: .developers, tier: .free,
                          summary: "See what's listening on which port, open it or stop it.")

    private(set) var processes: [ListeningProcess] = []
    private(set) var loading = false
    private(set) var failed = false
    private(set) var updated: Date?
    var confirming: Int32?
    var visible = false
    /// The Home card is on screen (it keeps the list fresh too).
    var homeVisible = false
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

    func refresh() {
        guard !ModuleRegistry.isPreview, !loading else { return }
        loading = true
        Task {
            let out = await Task.detached { DevCommand.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 8) }.value
            loading = false
            updated = .now
            // lsof exits 1 when nothing matches; that's just an empty list.
            guard let out, !out.timedOut else { failed = true; return }
            failed = false
            processes = PortsParsing.parse(out.stdout).map { var p = $0; p.canStop = Self.canSignal(p.pid); return p }
        }
    }

    /// True when this user may signal the process (it's theirs).
    static func canSignal(_ pid: Int32) -> Bool { pid > 1 && kill(pid, 0) == 0 }

    func terminate(_ pid: Int32) {
        confirming = nil
        guard Self.canSignal(pid) else { return }
        kill(pid, SIGTERM)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            refresh()
        }
    }

    var portCount: Int { processes.reduce(0) { $0 + $1.ports.count } }

    var homeCard: AnyView? { AnyView(PortsHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(PortsPanel(module: self)) }

    private func loadSample() {
        processes = [
            ListeningProcess(pid: 48211, name: "node", ports: [.init(port: 3000, address: "*"), .init(port: 9229, address: "127.0.0.1")], canStop: true),
            ListeningProcess(pid: 1834, name: "postgres", ports: [.init(port: 5432, address: "127.0.0.1")], canStop: true),
            ListeningProcess(pid: 51022, name: "Python", ports: [.init(port: 8000, address: "*")], canStop: true),
            ListeningProcess(pid: 733, name: "ControlCenter", ports: [.init(port: 5000, address: "*"), .init(port: 7000, address: "*")], canStop: false),
        ]
        confirming = 51022
        updated = .now
    }
}

// MARK: - Parsing (pure, tested)

struct ListeningProcess: Identifiable, Equatable {
    struct Port: Equatable, Hashable {
        let port: Int
        let address: String
    }
    var id: Int32 { pid }
    let pid: Int32
    var name: String
    var ports: [Port]
    var canStop = false
}

enum PortsParsing {
    /// Parses `lsof -F pcn` output: "p<pid>", "c<command>", "f<fd>", "n<address:port>" lines.
    static func parse(_ text: String) -> [ListeningProcess] {
        var result: [ListeningProcess] = []
        var current: ListeningProcess?
        func flush() {
            if let c = current, !c.ports.isEmpty { result.append(c) }
            current = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                flush()
                if let pid = Int32(value) { current = ListeningProcess(pid: pid, name: "", ports: []) }
            case "c":
                if current?.name.isEmpty == true { current?.name = value }
            case "n":
                guard let port = endpoint(value), let c = current, !c.ports.contains(where: { $0.port == port.port }) else { continue }
                current?.ports.append(port)
            default:
                continue
            }
        }
        flush()
        for i in result.indices { result[i].ports.sort { $0.port < $1.port } }
        return result.sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }
    }

    /// "*:3000", "127.0.0.1:5432", "[::1]:8080" → port and address.
    static func endpoint(_ name: String) -> ListeningProcess.Port? {
        let main = name.split(separator: "->").first.map(String.init) ?? name
        guard let colon = main.lastIndex(of: ":"), let port = Int(main[main.index(after: colon)...]) else { return nil }
        var address = String(main[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return .init(port: port, address: address)
    }

    /// Whether "Open in browser" makes sense: skips well-known database, mail and system ports.
    static func isLikelyHTTP(_ port: Int) -> Bool {
        let notHTTP: Set<Int> = [21, 22, 25, 53, 110, 143, 445, 548, 587, 993, 995, 1433, 1521, 3306, 3389, 5432, 5900,
                                 6379, 6380, 7000, 9092, 9229, 11211, 27017, 27018, 5672, 2181]
        return !notHTTP.contains(port)
    }
}

// MARK: - Panel

private struct PortsPanel: View {
    @Bindable var module: PortsAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AddOnHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Ports & processes",
                            subtitle: subtitle, tint: AddOnCategory.developers.tint)
                if !module.processes.isEmpty {
                    // Orbit peeks out of a port to see who's listening.
                    DevPortOrbit(size: 40).help("Orbit is peeking through your ports")
                }
                DevIconButton(symbol: "arrow.clockwise", help: "Refresh") { module.refresh() }
            }
            if module.failed {
                DevEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't list ports",
                              message: "lsof didn't answer in time. Try again in a moment.", tint: Tokens.attention)
            } else if module.processes.isEmpty {
                DevEmptyState(symbol: "powerplug", title: module.updated == nil ? "Looking…" : "Nothing is listening",
                              message: "Start a dev server and it shows up here.",
                              art: AnyView(DevPortOrbit(size: 72, awake: module.updated == nil)))
            } else {
                NotchScroll {
                    VStack(spacing: 6) {
                        ForEach(module.processes) { p in row(p) }
                    }
                }
            }
        }
        .onAppear { module.visible = true; module.refresh() }
        .onDisappear { module.visible = false; module.confirming = nil }
    }

    var subtitle: String {
        let n = module.portCount
        return n == 1 ? "1 port listening" : "\(n) ports listening"
    }

    @ViewBuilder
    func row(_ p: ListeningProcess) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Tokens.live).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("pid \(String(p.pid))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.faint)
            }
            .frame(width: 120, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(p.ports, id: \.self) { port in portChip(port) }
            }
            Spacer(minLength: 6)
            if module.confirming == p.pid {
                Text("Stop \(p.name)?").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                GlassPillButton(title: "Cancel") { module.confirming = nil }
                PillButton(title: "Stop", fill: Tokens.error) { module.terminate(p.pid) }
            } else if p.canStop {
                GlassPillButton(title: "Stop", symbol: "stop.fill") { module.confirming = p.pid }
            } else {
                Text("System").font(.system(size: 11)).foregroundStyle(Tokens.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassCard(16)
    }

    @ViewBuilder
    func portChip(_ port: ListeningProcess.Port) -> some View {
        let local = port.address == "127.0.0.1" || port.address == "::1" || port.address == "localhost"
        if PortsParsing.isLikelyHTTP(port.port) {
            Button { DevActions.open("http://localhost:\(port.port)") } label: {
                HStack(spacing: 3) {
                    Text(":\(String(port.port))").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassSurface(Capsule(), interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Open http://localhost:\(port.port)\(local ? "" : " (open to the network)")")
        } else {
            Text(":\(String(port.port))").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Tokens.surface, in: Capsule())
                .help(local ? "Only this Mac" : "Open to the network")
        }
    }
}

/// Home: how many ports are listening, and the first few.
private struct PortsHomeCard: View {
    let module: PortsAddOn
    let open: () -> Void

    var body: some View {
        let n = module.portCount
        let list = module.processes.prefix(3).compactMap { p in p.ports.first.map { ":\(String($0.port)) \(p.name)" } }
        DevSecHomeCard(label: "Ports",
                       title: module.failed ? "Couldn't list ports" : (n == 0 ? "Nothing listening" : "\(n) port\(n == 1 ? "" : "s") listening"),
                       detail: list.isEmpty ? "Start a dev server and it shows up here" : list.joined(separator: " · "),
                       open: open) {
            DevPortOrbit(size: 50, awake: n > 0)
        }
        .onAppear { module.homeVisible = true; module.refresh() }
        .onDisappear { module.homeVisible = false }
    }
}
