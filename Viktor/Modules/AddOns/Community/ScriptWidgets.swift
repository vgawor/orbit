import AppKit
import CryptoKit
import SwiftUI

/// Orbit Widgets: community add-ons written in any language.
///
/// A widget is a folder in ~/Library/Application Support/Orbit/Widgets/<folder>/ with a
/// `widget.json` manifest and a script. Orbit runs the script every `interval` seconds and shows
/// the JSON it prints as a Home card, a tab and an optional peek chip. See docs/SDK.md.
///
/// Safety: a widget only runs after you press "Trust & run", and again whenever the script changes
/// (Orbit remembers a SHA-256 of the script). Scripts run without a shell, with a 20 s time limit.
enum ScriptWidgets {
    static var folder: URL { Storage.folder.appendingPathComponent("Widgets", isDirectory: true) }

    struct Manifest: Codable, Equatable {
        var id: String
        var name: String
        var description: String?
        var author: String?
        var category: String?
        /// Path of the script inside the widget folder, e.g. "run.sh". Must be executable.
        var run: String
        /// Arguments passed to the script.
        var args: [String]?
        /// Seconds between runs (min 10, default 300).
        var interval: Double?
        /// SF Symbol for the tab.
        var symbol: String?
    }

    /// What a widget script prints (all fields optional).
    struct Output: Codable, Equatable {
        struct Item: Codable, Equatable, Identifiable {
            var title: String
            var value: String?
            var url: String?
            var id: String { title + (value ?? "") }
        }
        var title: String?
        var value: String?
        var subtitle: String?
        var symbol: String?
        var tint: String?
        var progress: Double?
        var items: [Item]?
        var url: String?
        /// Short text for the peek chip, e.g. "21° Sthlm".
        var chip: String?
        /// Set to make Orbit nudge you, e.g. "Build failed".
        var attention: String?
    }

    static func parseManifest(_ data: Data) -> Manifest? {
        guard var m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        m.id = m.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !m.id.isEmpty, !m.name.isEmpty, !m.run.isEmpty, !m.run.contains("..") else { return nil }
        return m
    }

    /// Uses the last JSON object the script printed (scripts may log before it).
    static func parseOutput(_ text: String) -> Output? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = try? JSONDecoder().decode(Output.self, from: Data(trimmed.utf8)) { return o }
        for line in trimmed.split(separator: "\n").reversed() {
            if let o = try? JSONDecoder().decode(Output.self, from: Data(line.utf8)) { return o }
        }
        return nil
    }

    static func color(_ hex: String?) -> Color? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func category(_ s: String?) -> AddOnCategory {
        AddOnCategory(rawValue: (s ?? "").lowercased()) ?? .productivity
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every widget folder with a valid manifest.
    @MainActor
    static func load() -> [ScriptWidgetModule] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("widget.json")),
                  let m = parseManifest(data) else { return nil }
            return ScriptWidgetModule(manifest: m, folder: dir)
        }
    }

    /// Runs the script off the main thread, without a shell, with a time limit.
    static func run(_ executable: URL, args: [String], in dir: URL, timeout: TimeInterval = 20) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = args
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment
                env["ORBIT_WIDGET"] = "1"
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data.prefix(256_000), as: UTF8.self)))
            }
        }
    }
}

/// One community widget, shown like any other add-on.
@MainActor
@Observable
final class ScriptWidgetModule: AddOnModule {
    let manifest: ScriptWidgets.Manifest
    let folder: URL
    var id: String { "widget.\(manifest.id)" }
    var title: String { manifest.name }
    var symbol: String { manifest.symbol ?? "puzzlepiece.extension.fill" }
    var addOn: AddOnInfo {
        AddOnInfo(category: ScriptWidgets.category(manifest.category), tier: .free,
                  summary: manifest.description ?? "A community widget.", author: manifest.author ?? "Community")
    }

    private(set) var output: ScriptWidgets.Output?
    private(set) var error: String?
    private(set) var lastRun: Date?
    private(set) var running = false
    private var timer: Timer?

    init(manifest: ScriptWidgets.Manifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
        output = Storage.load(ScriptWidgets.Output.self, from: "widget-\(manifest.id)")
    }

    var script: URL { folder.appendingPathComponent(manifest.run).standardizedFileURL }
    private var trustKey: String { "widgets.trusted.\(manifest.id)" }
    var isTrusted: Bool {
        guard let saved = UserDefaults.standard.string(forKey: trustKey) else { return false }
        return saved == ScriptWidgets.sha256(of: script)
    }
    var scriptChanged: Bool { UserDefaults.standard.string(forKey: trustKey) != nil && !isTrusted }

    func trust() {
        UserDefaults.standard.set(ScriptWidgets.sha256(of: script), forKey: trustKey)
        refresh()
        schedule()
    }

    func start() { if isTrusted { refresh(); schedule() } }
    func stop() { timer?.invalidate(); timer = nil }

    private func schedule() {
        timer?.invalidate()
        let every = max(manifest.interval ?? 300, 10)
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard isTrusted, !running else { return }
        // The script must stay inside its own folder.
        guard script.path.hasPrefix(folder.standardizedFileURL.path),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            error = "\(manifest.run) isn't an executable file in the widget's folder. Run chmod +x on it."
            return
        }
        running = true
        let script = script, args = manifest.args ?? [], folder = folder, id = manifest.id
        Task {
            let (status, text) = await ScriptWidgets.run(script, args: args, in: folder)
            running = false
            lastRun = .now
            if let o = ScriptWidgets.parseOutput(text) {
                output = o
                error = nil
                Storage.save(o, to: "widget-\(id)")
            } else {
                error = status == 0 ? "The script didn't print JSON. See docs/SDK.md." : "The script stopped with code \(status)."
            }
        }
    }

    var tint: Color { ScriptWidgets.color(output?.tint) ?? addOn.category.tint }

    var homeCard: AnyView? {
        guard isTrusted, let o = output else { return nil }
        return AnyView(ScriptWidgetCard(module: self, output: o, compact: true))
    }

    var peekChip: PeekChip? {
        guard isTrusted, let chip = output?.chip, !chip.isEmpty else { return nil }
        return PeekChip(symbol: output?.symbol ?? symbol, text: chip, tint: tint, priority: 1)
    }

    var attention: Attention? {
        guard isTrusted, let a = output?.attention, !a.isEmpty else { return nil }
        return Attention(id: "widget-\(manifest.id)-\(a)", symbol: output?.symbol ?? symbol, tint: tint,
                         label: manifest.name, priority: 2, headline: a)
    }

    var panel: AnyView { AnyView(ScriptWidgetPanel(module: self)) }
}

private struct ScriptWidgetCard: View {
    let module: ScriptWidgetModule
    let output: ScriptWidgets.Output
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: output.symbol ?? module.symbol).foregroundStyle(module.tint)
                Text(output.title ?? module.manifest.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let v = output.value {
                Text(v).font(.system(size: compact ? 24 : 34, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            if let s = output.subtitle {
                Text(s).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(compact ? 1 : 3)
            }
            if let p = output.progress {
                ProgressView(value: min(max(p, 0), 1)).tint(module.tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
        .contentShape(Rectangle())
        .onTapGesture { if let u = output.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
    }
}

private struct ScriptWidgetPanel: View {
    let module: ScriptWidgetModule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddOnHeader(symbol: module.symbol, title: module.manifest.name,
                        subtitle: "Community widget" + (module.manifest.author.map { " · by \($0)" } ?? ""), tint: module.tint)
            if !module.isTrusted {
                HStack(alignment: .top, spacing: 14) {
                    // Orbit, wide-eyed: a script wants to run. A changed script gets a nudge.
                    OrbitView(size: 46, mood: .wide, motion: module.scriptChanged ? .nudge : .idle, tint: Tokens.attention)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(module.scriptChanged ? "This widget's script has changed." : "This widget runs a script on your Mac.")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Only trust scripts you wrote or have read. It runs \(module.manifest.run) in \(module.folder.path) every \(Int(max(module.manifest.interval ?? 300, 10))) seconds.")
                            .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            PillButton(title: "Trust & run") { module.trust() }
                            GlassPillButton(title: "Show script") { NSWorkspace.shared.activateFileViewerSelecting([module.script]) }
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard(20)
            } else if let o = module.output {
                if let a = o.attention, !a.isEmpty {
                    HStack(spacing: 10) {
                        OrbitView(size: 24, mood: .wide, motion: .nudge, tint: module.tint)
                        Text(a).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassCard(16)
                }
                ScriptWidgetCard(module: module, output: o)
                if let items = o.items, !items.isEmpty {
                    NotchScroll {
                        VStack(spacing: 2) {
                            ForEach(items) { item in
                                HStack {
                                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    if let v = item.value { Text(v).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Tokens.secondary) }
                                }
                                .padding(.vertical, 6).padding(.horizontal, 10)
                                .contentShape(Rectangle())
                                .onTapGesture { if let u = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
                            }
                        }
                    }
                    .glassCard(20)
                }
            } else {
                // Nothing printed yet: Orbit works while the script runs and naps until it has something.
                VStack(spacing: 10) {
                    OrbitView(size: 46, mood: module.error == nil ? .normal : .grumpy,
                              motion: module.running ? .working : module.error == nil ? .sleep : .idle)
                    Text(module.running ? "Running the script…" : module.error == nil ? "No output yet. Press Run now to try it." : "No output yet.")
                        .font(.system(size: 12.5)).foregroundStyle(Tokens.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .glassCard(20)
            }
            if let e = module.error {
                HStack(spacing: 8) {
                    OrbitView(size: 18, mood: .grumpy, motion: .still)
                    Text(e).font(.system(size: 11.5)).foregroundStyle(Tokens.error)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if module.isTrusted {
                    OrbitView(size: 18, mood: module.error == nil && module.output != nil ? .happy : .normal,
                              motion: module.running ? .working : .idle)
                }
                if let t = module.lastRun {
                    Text("Updated \(t.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(Tokens.faint)
                }
                Spacer()
                GlassPillButton(title: "Open folder", symbol: "folder") { NSWorkspace.shared.open(module.folder) }
                if module.isTrusted { GlassPillButton(title: "Run now", symbol: "arrow.clockwise") { module.refresh() } }
            }
        }
    }
}
