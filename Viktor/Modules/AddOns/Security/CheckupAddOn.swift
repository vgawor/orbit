import Foundation
import SwiftUI

// MARK: - Logic

extension SecurityKit {
    /// Runs a command (argument array, never a shell) with a timeout. Returns nil if it couldn't
    /// start or ran too long. Output is stdout and stderr together.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationReason == .uncaughtSignal { cont.resume(returning: nil); return }
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    enum CheckState: String, Equatable, Sendable { case good, warn, unknown }

    struct CheckResult: Equatable, Sendable {
        var state: CheckState
        /// "On", "Off", "After 5 min"…
        var value: String
    }

    enum CheckID: String, CaseIterable, Sendable {
        case fileVault, firewall, sip, gatekeeper, updates, screenLock

        var title: String {
            switch self {
            case .fileVault: "FileVault disk encryption"
            case .firewall: "Firewall"
            case .sip: "System Integrity Protection"
            case .gatekeeper: "Gatekeeper"
            case .updates: "Automatic update checks"
            case .screenLock: "Password after sleep"
            }
        }

        var symbol: String {
            switch self {
            case .fileVault: "lock.doc.fill"
            case .firewall: "flame.fill"
            case .sip: "cpu"
            case .gatekeeper: "checkmark.seal.fill"
            case .updates: "arrow.triangle.2.circlepath"
            case .screenLock: "lock.display"
            }
        }

        /// One line on how to fix it.
        var fix: String {
            switch self {
            case .fileVault: "Turn on FileVault in Privacy & Security so a lost Mac can't be read."
            case .firewall: "Turn on the firewall in Network → Firewall to block unwanted connections."
            case .sip: "Restart into Recovery and run “csrutil enable” in Terminal."
            case .gatekeeper: "Allow apps from the App Store and known developers in Privacy & Security."
            case .updates: "Turn on automatic updates in General → Software Update."
            case .screenLock: "Require your password immediately in Lock Screen settings."
            }
        }

        /// The System Settings pane that fixes it, if there is one.
        var settingsURL: String? {
            switch self {
            case .fileVault: "x-apple.systempreferences:com.apple.preference.security?FileVault"
            case .firewall: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
            case .sip: nil
            case .gatekeeper: "x-apple.systempreferences:com.apple.preference.security?General"
            case .updates: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
            case .screenLock: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
            }
        }

        var command: (String, [String]) {
            switch self {
            case .fileVault: ("/usr/bin/fdesetup", ["status"])
            case .firewall: ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
            case .sip: ("/usr/bin/csrutil", ["status"])
            case .gatekeeper: ("/usr/sbin/spctl", ["--status"])
            case .updates: ("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"])
            case .screenLock: ("/usr/sbin/sysadminctl", ["-screenLock", "status"])
            }
        }

        func parse(status: Int32, output: String) -> CheckResult {
            switch self {
            case .fileVault: CheckParse.fileVault(output)
            case .firewall: CheckParse.firewall(output)
            case .sip: CheckParse.sip(output)
            case .gatekeeper: CheckParse.gatekeeper(output)
            case .updates: CheckParse.updates(status: status, output: output)
            case .screenLock: CheckParse.screenLock(output)
            }
        }
    }

    /// Reads each command's output. Anything unexpected becomes "unknown" (grey), never a false alarm.
    enum CheckParse {
        static func fileVault(_ s: String) -> CheckResult {
            if s.contains("FileVault is On") { return .init(state: .good, value: "On") }
            if s.contains("FileVault is Off") {
                return s.contains("progress") ? .init(state: .warn, value: "Turning on…") : .init(state: .warn, value: "Off")
            }
            if s.contains("in progress") { return .init(state: .warn, value: "Encrypting…") }
            return .init(state: .unknown, value: "Unknown")
        }

        static func firewall(_ s: String) -> CheckResult {
            if s.contains("State = 1") || s.contains("State = 2") || s.contains("is enabled") { return .init(state: .good, value: "On") }
            if s.contains("State = 0") || s.contains("is disabled") { return .init(state: .warn, value: "Off") }
            return .init(state: .unknown, value: "Unknown")
        }

        static func sip(_ s: String) -> CheckResult {
            let l = s.lowercased()
            if l.contains("status: enabled") { return .init(state: .good, value: "On") }
            if l.contains("status: disabled") { return .init(state: .warn, value: "Off") }
            if l.contains("custom configuration") { return .init(state: .warn, value: "Partly off") }
            return .init(state: .unknown, value: "Unknown")
        }

        static func gatekeeper(_ s: String) -> CheckResult {
            if s.contains("assessments enabled") { return .init(state: .good, value: "On") }
            if s.contains("assessments disabled") { return .init(state: .warn, value: "Off") }
            return .init(state: .unknown, value: "Unknown")
        }

        /// The key is missing until someone changes it, and macOS checks by default.
        static func updates(status: Int32, output: String) -> CheckResult {
            let v = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == 0 { return v == "0" ? .init(state: .warn, value: "Off") : .init(state: .good, value: "On") }
            if output.contains("does not exist") { return .init(state: .good, value: "On") }
            return .init(state: .unknown, value: "Unknown")
        }

        /// `sysadminctl -screenLock status` prints e.g. "screenLock delay is immediate",
        /// "screenLock delay is 300 seconds" or "screenLock is off".
        static func screenLock(_ s: String) -> CheckResult {
            let l = s.lowercased()
            if l.contains("screenlock is off") { return .init(state: .warn, value: "Off") }
            guard let r = l.range(of: "screenlock delay is ") else { return .init(state: .unknown, value: "Can't read") }
            let rest = l[r.upperBound...]
            if rest.hasPrefix("immediate") { return .init(state: .good, value: "Immediately") }
            let digits = rest.prefix { $0.isNumber }
            guard let secs = Int(digits) else { return .init(state: .unknown, value: "Can't read") }
            let label = secs < 60 ? "After \(secs) s" : "After \(secs / 60) min"
            return .init(state: secs <= 5 ? .good : .warn, value: secs == 0 ? "Immediately" : label)
        }
    }
}

// MARK: - Module

/// Read-only checks of the Mac's main security settings, with how to fix each one.
@MainActor
@Observable
final class CheckupAddOn: AddOnModule {
    let id = "addon.checkup"
    let title = "Checkup"
    let symbol = "checkmark.shield.fill"
    let addOn = AddOnInfo(category: .security, tier: .pro,
                          summary: "Checks FileVault, firewall, Gatekeeper, updates and more, and shows how to fix them.")

    private(set) var results: [SecurityKit.CheckID: SecurityKit.CheckResult] = [:]
    private(set) var running = false
    private(set) var checkedAt: Date?
    private let ctx: AddOnContext

    init(_ ctx: AddOnContext) {
        self.ctx = ctx
        if ModuleRegistry.isPreview {
            results = [.fileVault: .init(state: .good, value: "On"), .firewall: .init(state: .warn, value: "Off"),
                       .sip: .init(state: .good, value: "On"), .gatekeeper: .init(state: .good, value: "On"),
                       .updates: .init(state: .good, value: "On"), .screenLock: .init(state: .warn, value: "After 5 min")]
            checkedAt = .now
        }
    }

    /// Runs every check at once, off the main thread.
    func run() {
        guard !running, !ModuleRegistry.isPreview else { return }
        running = true
        Task {
            let found = await withTaskGroup(of: (SecurityKit.CheckID, SecurityKit.CheckResult).self) { group in
                for check in SecurityKit.CheckID.allCases {
                    group.addTask {
                        let (exe, args) = check.command
                        guard let out = await SecurityKit.run(exe, args) else {
                            return (check, .init(state: .unknown, value: "Can't read"))
                        }
                        return (check, check.parse(status: out.status, output: out.output))
                    }
                }
                var all: [SecurityKit.CheckID: SecurityKit.CheckResult] = [:]
                for await (id, r) in group { all[id] = r }
                return all
            }
            results = found
            checkedAt = .now
            running = false
        }
    }

    var goodCount: Int { results.values.filter { $0.state == .good }.count }
    var warnCount: Int { results.values.filter { $0.state == .warn }.count }

    /// Runs the checks if they've never run or are more than an hour old (for the Home card).
    func runIfStale() {
        guard checkedAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true else { return }
        run()
    }

    /// What Orbit the inspector makes of it.
    var verdict: SecInspectorOrbit.Verdict {
        SecurityKit.CheckScore.verdict(results.values.map(\.state), running: running)
    }

    var homeCard: AnyView? { AnyView(SecCheckupHomeCard(module: self) { [ctx, id] in ctx.openPanel(id) }) }

    var panel: AnyView { AnyView(SecCheckupPanel(module: self)) }
}

extension SecurityKit {
    enum CheckScore {
        /// Checking while running; warn if any check needs a look; good when every check came back good;
        /// otherwise (nothing yet, or some couldn't be read) unknown.
        static func verdict(_ states: [CheckState], running: Bool) -> SecInspectorOrbit.Verdict {
            if running { return .checking }
            if states.contains(.warn) { return .warn }
            if !states.isEmpty, states.allSatisfy({ $0 == .good }) { return .good }
            return .unknown
        }
    }
}

/// Home: the checkup score, with a dot per check.
struct SecCheckupHomeCard: View {
    let module: CheckupAddOn
    let open: () -> Void

    var body: some View {
        let total = SecurityKit.CheckID.allCases.count
        let firstWarn = SecurityKit.CheckID.allCases.first { module.results[$0]?.state == .warn }
        let title = module.results.isEmpty ? (module.running ? "Checking…" : "Not checked yet")
            : (module.warnCount == 0 ? "All \(module.goodCount) of \(total) look good" : "\(module.goodCount) of \(total) look good")
        let detail = firstWarn.map { "\($0.title): \(module.results[$0]?.value ?? "")" + (module.warnCount > 1 ? " +\(module.warnCount - 1)" : "") }
            ?? (module.checkedAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "FileVault, firewall, updates and more")
        DevSecHomeCard(label: "Security checkup", title: title, detail: detail,
                       detailTint: firstWarn == nil ? Tokens.secondary : Tokens.attention, open: open) {
            SecInspectorOrbit(size: 50, verdict: module.verdict, calm: true)
        } trailing: {
            HStack(spacing: 4) {
                ForEach(SecurityKit.CheckID.allCases, id: \.self) { check in
                    let state = module.results[check]?.state
                    SecStatusDot(color: state == .good ? Tokens.live : state == .warn ? Tokens.attention : Tokens.faint, size: 7)
                        .help(check.title)
                }
            }
        }
        .onAppear { module.runIfStale() }
    }
}

// MARK: - View

struct SecCheckupPanel: View {
    let module: CheckupAddOn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AddOnHeader(symbol: "checkmark.shield.fill", title: "Security checkup", subtitle: subtitle, tint: SecurityAddOns.tint)
                // Orbit the inspector: busy while checking, happy when all is well, alarmed at a warning.
                SecInspectorOrbit(size: 44, verdict: module.verdict)
                    .padding(.trailing, 4)
                GlassPillButton(title: "Re-check", symbol: "arrow.clockwise") { module.run() }
            }
            NotchScroll {
                VStack(spacing: 6) {
                    ForEach(SecurityKit.CheckID.allCases, id: \.self) { check in
                        SecCheckRow(check: check, result: module.results[check], running: module.running)
                    }
                }
            }
        }
        .onAppear { module.run() }
    }

    private var subtitle: String {
        if module.results.isEmpty { return module.running ? "Checking…" : "Read-only checks of this Mac's settings" }
        let total = SecurityKit.CheckID.allCases.count
        let when = module.checkedAt.map { " · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        if module.warnCount == 0 { return "All \(module.goodCount) of \(total) look good" + when }
        return "\(module.warnCount) to look at, \(module.goodCount) of \(total) look good" + when
    }
}

struct SecCheckRow: View {
    let check: SecurityKit.CheckID
    let result: SecurityKit.CheckResult?
    let running: Bool

    var body: some View {
        let state = result?.state ?? .unknown
        let color: Color = switch state {
        case .good: Tokens.live
        case .warn: Tokens.attention
        case .unknown: Tokens.faint
        }
        HStack(spacing: 12) {
            Image(systemName: check.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state == .warn ? Tokens.attention : .white)
                .frame(width: 30, height: 30).glassSurface(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.system(size: 13, weight: .semibold))
                Text(state == .good ? "Looks good." : state == .warn ? check.fix
                     : (result == nil ? (running ? "Checking…" : "Not checked yet.") : "Couldn't read this without admin rights."))
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                SecStatusDot(color: color, size: 7)
                Text(result?.value ?? "—").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state == .unknown ? Tokens.secondary : .white)
            }
            .fixedSize()
            if state == .warn, let url = check.settingsURL {
                GlassPillButton(title: "Open", symbol: "arrow.up.forward") { SecurityKit.openSettings(url) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassCard(18)
    }
}
