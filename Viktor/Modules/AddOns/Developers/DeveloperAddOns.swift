import AppKit
import SwiftUI

/// Developers add-ons. Return each one here; they show up in Settings → Add-ons.
@MainActor
enum DeveloperAddOns {
    static func make(_ ctx: AddOnContext) -> [any NotchModule] {
        [GitHubActionsAddOn(ctx), PortsAddOn(ctx), DockerAddOn(ctx), DevToolboxAddOn(ctx), UptimeAddOn(ctx)]
    }
}

// MARK: - Running commands

/// Runs a command (argument array, never a shell string) off the main thread, with a timeout.
enum DevCommand {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Blocking: call from a detached task. Returns nil when the command can't be started.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Output? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:" + FileManager.default.homeDirectoryForCurrentUser.path + "/.docker/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }

        // Read both pipes while the command runs, so a full pipe buffer can't stall it.
        let outBox = Box(), errBox = Box()
        let reads = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            reads.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                reads.leave()
            }
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        _ = reads.wait(timeout: .now() + 2)
        return Output(status: p.isRunning ? -1 : p.terminationStatus,
                      stdout: String(decoding: outBox.data, as: UTF8.self),
                      stderr: String(decoding: errBox.data, as: UTF8.self),
                      timedOut: timedOut)
    }
}

// MARK: - Small shared helpers

enum DevFormat {
    /// "now", "5m", "3h", "2d" — how long ago something happened.
    static func age(_ date: Date, now: Date = .now) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Parses GitHub-style ISO 8601 dates ("2026-10-28T09:12:44Z"), with or without fractions.
    static func isoDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}

@MainActor
enum DevActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// A plain text field on glass, used by the add-on panels.
struct DevField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 12).frame(height: 30)
            .glassSurface(Capsule())
            .onSubmit(onSubmit)
    }
}

/// A small round icon button (refresh, remove, copy…).
struct DevIconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .glassSurface(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// A centred message for empty and error states. Pass `art` to show an Orbit scene instead of the symbol.
struct DevEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = Tokens.secondary
    var art: AnyView? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let art {
                art.padding(.bottom, 2)
            } else {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
            }
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small rounded tag, e.g. a branch name or port.
struct DevTag: View {
    let text: String
    var tint: Color = Tokens.secondary
    var body: some View {
        Text(text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
