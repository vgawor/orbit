import AppKit
import SwiftUI
import ViktorKit

/// Settings → Developer: the local API, the viktor command, Claude Code hooks and GitHub.
struct DeveloperSettings: View {
    let api: LocalAPIServer?
    let agents: AgentsModule?

    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var hooksInstalled = ClaudeHookInstaller.isInstalled()
    @State private var githubToken = ""
    @State private var hasSavedToken = Secrets.get("github") != nil
    @State private var message: String?
    @State private var alertOnFinish = true

    var body: some View {
        Form {
            Section("Local API") {
                LabeledContent("Status") {
                    if api?.isRunning == true {
                        Label("Running on \(APIConfig.host):\(APIConfig.port)", systemImage: "circle.fill")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Text(api?.lastError ?? "Not running").foregroundStyle(.red)
                    }
                }
                LabeledContent("Token") {
                    Button("Copy token") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(APIConfig.readToken() ?? "", forType: .string)
                        message = "Token copied"
                    }
                }
                Text("Only apps on this Mac can connect, and only with the token. Requests from web pages are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Command line tool") {
                LabeledContent("viktor") {
                    if cliInstalled {
                        Text(CLIInstaller.linkPath).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Button("Install") { run { try CLIInstaller.install(); cliInstalled = true; return "Installed \(CLIInstaller.linkPath)" } }
                    }
                }
                if cliInstalled && !CLIInstaller.isOnPath {
                    Text("Add ~/.local/bin to your PATH to type just `viktor`.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude Code") {
                Toggle("Show Claude Code activity in the notch", isOn: Binding(
                    get: { hooksInstalled },
                    set: { on in
                        run {
                            if on {
                                if !cliInstalled { try CLIInstaller.install(); cliInstalled = true }
                                try ClaudeHookInstaller.install(cliPath: CLIInstaller.linkPath)
                            } else {
                                try ClaudeHookInstaller.uninstall()
                            }
                            hooksInstalled = ClaudeHookInstaller.isInstalled()
                            return on ? "Hooks added. Restart Claude Code sessions to pick them up." : "Hooks removed."
                        }
                    }))
                Toggle("Alert when Claude finishes a turn", isOn: $alertOnFinish)
                    .onChange(of: alertOnFinish) { _, v in agents?.alertOnFinish = v }
                Text("Adds hooks to ~/.claude/settings.json. A backup is saved next to it first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("GitHub") {
                if hasSavedToken {
                    LabeledContent("Token") {
                        Button("Remove") { Secrets.set(nil, for: "github"); hasSavedToken = false; refreshGitHub() }
                    }
                } else {
                    SecureField("Personal access token", text: $githubToken)
                    HStack {
                        Text("Leave empty to use the gh tool's login.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save") {
                            Secrets.set(githubToken.trimmingCharacters(in: .whitespaces), for: "github")
                            githubToken = ""
                            hasSavedToken = Secrets.get("github") != nil
                            refreshGitHub()
                        }
                        .disabled(githubToken.isEmpty)
                    }
                }
                if let gh = agents?.github {
                    LabeledContent("Reviews waiting") {
                        switch gh.status {
                        case .ok: Text("\(gh.reviews.count)")
                        case .loading: ProgressView().controlSize(.small)
                        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
                        case .failed(let why): Text(why).foregroundStyle(.red)
                        }
                    }
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            alertOnFinish = agents?.alertOnFinish ?? true
            hooksInstalled = ClaudeHookInstaller.isInstalled()
            cliInstalled = CLIInstaller.isInstalled
        }
    }

    private func refreshGitHub() {
        Task { await agents?.github.refresh() }
    }

    private func run(_ action: () throws -> String) {
        do { message = try action() } catch { message = error.localizedDescription }
    }
}

/// Links ~/.local/bin/viktor to the copy inside Viktor.app.
enum CLIInstaller {
    static var linkPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/viktor").path
    }

    static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/viktor").path
    }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledPath
    }

    static var isOnPath: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0.hasSuffix("/.local/bin") }
    }

    static func install() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundledPath) else {
            throw NSError(domain: "Viktor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The viktor tool isn't inside this copy of the app. Rebuild with scripts/build-app.sh."])
        }
        try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Only replace an older link to an Orbit app; never someone else's file.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            guard existing.hasSuffix("Contents/Helpers/viktor") else {
                throw NSError(domain: "Viktor", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(linkPath) already points somewhere else. Remove it first."])
            }
            try fm.removeItem(atPath: linkPath)
        } else if fm.fileExists(atPath: linkPath) {
            throw NSError(domain: "Viktor", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(linkPath) already exists. Remove it first."])
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledPath)
    }
}
