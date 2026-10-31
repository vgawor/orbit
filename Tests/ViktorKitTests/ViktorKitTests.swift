import Foundation
import Testing
@testable import ViktorKit

@Suite("Local API types")
struct APITypesTests {
    @Test func itemRoundTrips() throws {
        let item = APIItem(id: "deploy", title: "Deploy", subtitle: "Uploading", progress: 0.4, status: .active, ttl: 60, source: "terminal")
        let data = try APIJSON.encoder.encode(item)
        let back = try APIJSON.decoder.decode(APIItem.self, from: data)
        #expect(back.id == "deploy")
        #expect(back.progress == 0.4)
        #expect(back.status == .active)
        #expect(back.expiresAt != nil)
    }

    @Test func itemDecodesMinimalJSON() throws {
        let json = #"{"id":"x","title":"Hello","status":"success","updated":"2026-10-27T10:00:00Z"}"#
        let item = try APIJSON.decoder.decode(APIItem.self, from: Data(json.utf8))
        #expect(item.title == "Hello")
        #expect(item.status == .success)
        #expect(item.progress == nil)
    }

    @Test func askRequestRoundTrips() throws {
        let ask = AskRequest(title: "Deploy?", actions: ["Cancel", "Deploy"], timeout: 30)
        let back = try APIJSON.decoder.decode(AskRequest.self, from: APIJSON.encoder.encode(ask))
        #expect(back.actions == ["Cancel", "Deploy"])
    }
}

@Suite("Claude Code hook installer")
struct HookInstallerTests {
    private func tempSettings(_ contents: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viktor-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let contents { try Data(contents.utf8).write(to: url) }
        return url
    }

    private func load(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func installKeepsOtherSettingsAndHooks() throws {
        let url = try tempSettings(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"afplay x"}]}]}}"#)
        try ClaudeHookInstaller.install(cliPath: "/usr/local/bin/viktor", at: url)
        let root = try load(url)
        #expect(root["model"] as? String == "opus")
        let hooks = root["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == Set(ClaudeHookInstaller.events))
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 2) // the user's own hook is kept
        #expect(ClaudeHookInstaller.isInstalled(at: url))
        #expect(FileManager.default.fileExists(atPath: url.path + ".viktor-backup"))
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        let url = try tempSettings("{}")
        try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        let hooks = try load(url)["hooks"] as! [String: Any]
        for event in ClaudeHookInstaller.events {
            #expect((hooks[event] as! [[String: Any]]).count == 1, "\(event) duplicated")
        }
    }

    @Test func installOnMissingFileCreatesIt() throws {
        let url = try tempSettings(nil)
        try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        #expect(ClaudeHookInstaller.isInstalled(at: url))
    }

    @Test func uninstallRemovesOnlyViktor() throws {
        let url = try tempSettings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"afplay x"}]}]}}"#)
        try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        try ClaudeHookInstaller.uninstall(at: url)
        let hooks = try load(url)["hooks"] as! [String: Any]
        #expect(Array(hooks.keys) == ["Stop"])
        #expect(!ClaudeHookInstaller.isInstalled(at: url))
    }

    @Test func installsTheApprovalHookForTerminalSessions() throws {
        let url = try tempSettings("{}")
        try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        let hooks = try load(url)["hooks"] as! [String: Any]
        let group = (hooks["PermissionRequest"] as! [[String: Any]]).first!
        #expect(group["matcher"] as? String == "*")
        let hook = (group["hooks"] as! [[String: Any]]).first!
        #expect(hook["command"] as? String == "\"/a/viktor\" hook permission --terminal")
        #expect(hook["timeout"] as? Int == ClaudeHookInstaller.permissionTimeout)
        // Orbit hands the question back to the terminal before Claude Code gives up on the hook.
        #expect(AgentPermission.terminalAnswerTimeout < Double(ClaudeHookInstaller.permissionTimeout - 10))
    }

    @Test func refusesNonObjectFile() throws {
        let url = try tempSettings("[1,2,3]")
        #expect(throws: ClaudeHookInstaller.InstallError.self) {
            try ClaudeHookInstaller.install(cliPath: "/a/viktor", at: url)
        }
    }
}
