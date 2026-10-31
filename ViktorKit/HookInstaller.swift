import Foundation

/// Adds or removes Orbit's hooks in Claude Code's settings.json, leaving everything else as it was.
/// A copy of the previous file is saved as settings.json.viktor-backup before any change.
public enum ClaudeHookInstaller {
    /// The Claude Code events Orbit listens to.
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd",
                                "PermissionRequest"]
    /// Text that marks a hook command as Orbit's.
    public static let marker = "hook claude"
    /// The approval hook: asks Allow/Deny in the notch first, then falls back to the terminal's own question.
    public static let permissionMarker = "hook permission --terminal"
    /// Seconds Claude Code waits for the approval hook. Orbit gives up a bit earlier and lets the terminal ask.
    public static let permissionTimeout = 150

    public static var defaultSettingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public enum InstallError: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): "Couldn't read Claude Code settings: \(why)"
            }
        }
    }

    public static func isInstalled(at url: URL = defaultSettingsURL) -> Bool {
        guard let root = try? load(url), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isViktorGroup)
        }
    }

    /// `cliPath` is the absolute path of the viktor command, e.g. ~/.local/bin/viktor.
    public static func install(cliPath: String, at url: URL = defaultSettingsURL) throws {
        var root = try load(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = "\"\(cliPath)\" \(marker)"
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isViktorGroup($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" { group["matcher"] = "*" }
            if event == "PermissionRequest" {
                group = ["matcher": "*", "hooks": [["type": "command", "command": "\"\(cliPath)\" \(permissionMarker)",
                                                    "timeout": permissionTimeout]]]
            }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root, to: url)
    }

    public static func uninstall(at url: URL = defaultSettingsURL) throws {
        var root = try load(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).filter { !isViktorGroup($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root, to: url)
    }

    private static func isViktorGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            guard let c = $0["command"] as? String else { return false }
            return c.contains(marker) || c.contains(permissionMarker)
        }
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadable("it isn't a JSON object")
            }
            return obj
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.unreadable(error.localizedDescription)
        }
    }

    private static func save(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("viktor-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
