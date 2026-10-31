import AppKit
import SwiftUI

/// Your SSH sessions at a glance (Dots: "Keep open sessions visible… check elapsed time and tunnels,
/// return to your terminal or connect to a saved host"). Reads running `ssh` processes and ~/.ssh/config.
@MainActor
@Observable
final class SSHModule: NotchModule {
    let id = "ssh"
    let title = "SSH"
    let symbol = "server.rack"

    struct Session: Identifiable, Equatable {
        let id: Int32          // process id
        let host: String
        let elapsed: String    // e.g. "12m", "2h 05m"
        let tunnels: [String]  // e.g. "L 5432→db:5432"
    }

    private(set) var sessions: [Session] = []
    private(set) var savedHosts: [String] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        Task {
            let (s, h) = await Task.detached { (Self.readSessions(), Self.readSavedHosts()) }.value
            sessions = s
            savedHosts = h
        }
    }

    // MARK: Reading

    nonisolated static func readSessions() -> [Session] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,etime=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line -> Session? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { return nil }
            let args = parts[2].split(separator: " ").map(String.init)
            guard let exe = args.first, exe == "ssh" || exe.hasSuffix("/ssh") else { return nil }
            return parse(pid: pid, etime: String(parts[1]), args: Array(args.dropFirst()))
        }
    }

    /// Picks the host and any -L/-R/-D tunnels out of an ssh command line.
    nonisolated static func parse(pid: Int32, etime: String, args: [String]) -> Session? {
        let withValue: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
        var host: String?
        var tunnels: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-") {
                let flag = String(a.prefix(2))
                let value = a.count > 2 ? String(a.dropFirst(2)) : (i + 1 < args.count ? args[i + 1] : "")
                if ["-L", "-R", "-D"].contains(flag) { tunnels.append("\(flag.dropFirst()) \(value)") }
                if withValue.contains(flag) && a.count == 2 { i += 1 }
            } else if host == nil {
                host = a
                break   // the rest is the remote command
            }
            i += 1
        }
        guard let host else { return nil }
        return Session(id: pid, host: host.components(separatedBy: "@").last ?? host, elapsed: humanElapsed(etime), tunnels: tunnels)
    }

    /// ps etime "[[dd-]hh:]mm:ss" → "12m" / "2h 05m" / "3d 4h"
    nonisolated static func humanElapsed(_ e: String) -> String {
        var days = 0, rest = e
        if let dash = e.firstIndex(of: "-") { days = Int(e[..<dash]) ?? 0; rest = String(e[e.index(after: dash)...]) }
        let nums = rest.split(separator: ":").compactMap { Int($0) }
        let (h, m) = nums.count == 3 ? (nums[0], nums[1]) : (0, nums.first ?? 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(max(m, 1))m"
    }

    nonisolated static func readSavedHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("host "), !t.lowercased().hasPrefix("hostname") else { continue }
            for name in t.dropFirst(5).split(separator: " ") where !name.contains("*") && !name.contains("?") {
                hosts.append(String(name))
            }
        }
        return hosts
    }

    // MARK: Actions

    /// Opens a new Terminal window running `ssh host`.
    func connect(_ host: String) {
        let safe = host.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        let script = "tell application \"Terminal\"\n activate\n do script \"ssh \(safe)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// Brings your terminal app to the front.
    func returnToTerminal() {
        let terminals = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        for id in terminals {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
    }

    // MARK: Views

    var peekChip: PeekChip? {
        guard let s = sessions.first else { return nil }
        let more = sessions.count > 1 ? " +\(sessions.count - 1)" : ""
        return PeekChip(symbol: "server.rack", text: "\(s.host) · \(s.elapsed)\(more)", tint: Tokens.live, priority: 1)
    }

    var panel: AnyView { AnyView(SSHPanel(module: self)) }
}

struct SSHPanel: View {
    let module: SSHModule

    var body: some View {
        HStack(spacing: 10) {
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CardLabel("While active")
                        Spacer()
                        if !module.sessions.isEmpty {
                            Button("Return to terminal") { module.returnToTerminal() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                        }
                    }
                    if module.sessions.isEmpty {
                        Text("No SSH sessions open.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(module.sessions) { s in
                                HStack(alignment: .top, spacing: 10) {
                                    PulsingDot(color: Tokens.live, size: 7).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.host).font(.system(size: 13, weight: .semibold))
                                        if !s.tunnels.isEmpty {
                                            Text(s.tunnels.joined(separator: "  ·  ")).font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Tokens.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(s.elapsed).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tokens.secondary)
                                }
                                .padding(8)
                                .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            NotchCard {
                VStack(alignment: .leading, spacing: 6) {
                    CardLabel("Saved hosts")
                    if module.savedHosts.isEmpty {
                        Text("Hosts from ~/.ssh/config show here.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(module.savedHosts, id: \.self) { host in
                                Button { module.connect(host) } label: {
                                    HStack {
                                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
                                        Text(host).font(.system(size: 12.5))
                                        Spacer()
                                        Text("Connect").font(.system(size: 11)).foregroundStyle(Tokens.faint)
                                    }
                                    .padding(.vertical, 5).padding(.horizontal, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.surface2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(width: 250)
        }
        .onAppear { module.refresh() }
    }
}
