import Foundation

/// Your bots, saved on this Mac, and kept in step with their agents and schedules in the cloud.
@MainActor
@Observable
final class BotStore {
    private(set) var bots: [Bot]
    /// Why the last cloud update failed, per bot.
    private(set) var syncErrors: [String: String] = [:]
    private(set) var syncing: Set<String> = []
    /// Set by the runner: whether a bot has spent its monthly cap.
    var isOverCap: (Bot) -> Bool = { _ in false }
    /// Bots changed while their sync was running; synced once more afterwards.
    private var again: Set<String> = []

    private static let file = "bots"
    private static let environmentKey = "bots.environmentID"
    private let save: Bool

    init(bots: [Bot]? = nil, save: Bool = true) {
        self.save = save
        var loaded = bots ?? Storage.load([Bot].self, from: Self.file) ?? []
        // Built-in bots appear once, switched off, until you turn them on.
        for (i, builtIn) in [Bot.chiefOfStaff, Bot.accountManager].enumerated() where !loaded.contains(where: { $0.id == builtIn.id }) {
            loaded.insert(builtIn, at: min(i, loaded.count))
        }
        self.bots = loaded
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }

    /// Layout snapshots only: shows these bots without saving or syncing.
    func previewSet(_ bots: [Bot]) { self.bots = bots }

    /// Changes a bot locally, then updates the cloud.
    func update(_ id: String, _ change: (inout Bot) -> Void) {
        guard let i = bots.firstIndex(where: { $0.id == id }) else { return }
        change(&bots[i])
        persist()
        // Wait until the change settles (a time picker sends many), then update the cloud once.
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.sync(id)
        }
    }

    private var pending: [String: Task<Void, Never>] = [:]

    private func persist() { if save { Storage.save(bots, to: Self.file) } }

    private func set(_ id: String, _ change: (inout Bot) -> Void) {
        guard let i = bots.firstIndex(where: { $0.id == id }) else { return }
        change(&bots[i])
        persist()
    }

    // MARK: Cloud

    /// Sandboxes are kept per mode: your own Anthropic account and Orbit Pro have their own.
    private static var modeSuffix: String { CloudMode.active == .pro ? ".pro" : "" }

    static var environmentID: String? {
        get { UserDefaults.standard.string(forKey: environmentKey + modeSuffix) }
        set { UserDefaults.standard.set(newValue, forKey: environmentKey + modeSuffix) }
    }

    /// The sandbox for bots that search the web.
    static var webEnvironmentID: String? {
        get { UserDefaults.standard.string(forKey: environmentKey + ".web" + modeSuffix) }
        set { UserDefaults.standard.set(newValue, forKey: environmentKey + ".web" + modeSuffix) }
    }

    /// The bot's sandbox, made the first time it's needed.
    static func environment(for bot: Bot) async throws -> String {
        if bot.usesWeb {
            if webEnvironmentID == nil { webEnvironmentID = try await ManagedAgentsAPI.createEnvironment(web: true) }
            return webEnvironmentID!
        }
        if environmentID == nil { environmentID = try await ManagedAgentsAPI.createEnvironment() }
        return environmentID!
    }

    // MARK: Adding and removing bots

    func add(_ bot: Bot) {
        bots.append(bot)
        persist()
    }

    /// Removes a bot you made. Its cloud schedule and agent are archived (they can't be deleted);
    /// its runs stay in the history.
    func remove(_ id: String) async {
        guard let bot = bot(id), !bot.isBuiltIn else { return }
        bots.removeAll { $0.id == id }
        persist()
        if let depl = bot.deploymentID { _ = try? await ManagedAgentsAPI.call("POST", "deployments/\(depl)/archive", body: [:]) }
        if let agent = bot.agentID { _ = try? await ManagedAgentsAPI.call("POST", "agents/\(agent)/archive", body: [:]) }
    }

    func syncAll() async {
        for bot in bots where bot.enabled || bot.deploymentID != nil { await sync(bot.id) }
    }

    /// Switches a bot between Claude and ChatGPT, with that provider's default model.
    func setProvider(_ id: String, _ provider: BotProvider) {
        update(id) { bot in
            bot.provider = provider
            if !provider.models.contains(where: { $0.id == bot.model }) { bot.model = provider.defaultModel }
        }
    }

    /// Makes the cloud match the bot: agent (new version when its job changes), deployment
    /// (schedule and budget) and paused/unpaused. A bot that was never turned on stays local.
    func sync(_ id: String) async {
        guard ManagedAgentsAPI.isConfigured, let start = bot(id) else { return }
        guard start.enabled || start.deploymentID != nil else { return }
        // ChatGPT bots run on this Mac: only make sure a cloud schedule from before is paused.
        if start.engine == .chatgpt {
            guard let depl = start.deploymentID, start.deploymentPaused != true else { return }
            do {
                try await ManagedAgentsAPI.setDeploymentPaused(depl, true)
                set(id) { $0.deploymentPaused = true }
            } catch { syncErrors[id] = error.localizedDescription }
            return
        }
        if syncing.contains(id) { again.insert(id); return }
        syncing.insert(id)
        defer {
            syncing.remove(id)
            if again.remove(id) != nil { Task { await self.sync(id) } }
        }
        do {
            // Switched between your own key and Orbit Pro: archive the old schedule (so it can't
            // run twice) and set the bot up again with the new keys.
            let mode = CloudMode.current
            if start.agentID != nil, (start.cloudMode ?? CloudMode.own.rawValue) != mode.rawValue {
                let old = CloudMode(rawValue: start.cloudMode ?? "own") ?? .own
                if let depl = start.deploymentID {
                    _ = try? await CloudMode.$override.withValue(old) {
                        try await ManagedAgentsAPI.call("POST", "deployments/\(depl)/archive", body: [:])
                    }
                }
                set(id) { $0.agentID = nil; $0.agentVersion = nil; $0.deploymentID = nil; $0.syncedAgent = nil
                    $0.syncedDeployment = nil; $0.deploymentPaused = nil }
            }
            var bot = self.bot(id) ?? start
            let env = try await Self.environment(for: bot)
            if bot.agentID == nil || bot.syncedAgent != bot.agentFingerprint {
                let (agentID, version) = try await ManagedAgentsAPI.saveAgent(id: bot.agentID, bot.agentConfig)
                let fingerprint = bot.agentFingerprint
                set(id) { $0.agentID = agentID; $0.agentVersion = version; $0.syncedAgent = fingerprint; $0.cloudMode = mode.rawValue }
            }

            bot = self.bot(id) ?? bot
            let tz = TimeZone.current.identifier
            if bot.deploymentID == nil || bot.syncedDeployment != bot.deploymentFingerprint(timeZone: tz, environmentID: env) {
                let body = bot.deploymentBody(environmentID: env, timeZone: tz)
                let depl = try await ManagedAgentsAPI.saveDeployment(id: bot.deploymentID, body)
                let fingerprint = bot.deploymentFingerprint(timeZone: tz, environmentID: env)
                // A new deployment starts active.
                let wasNew = bot.deploymentID == nil
                set(id) { $0.deploymentID = depl; $0.syncedDeployment = fingerprint; if wasNew { $0.deploymentPaused = false } }
            }

            bot = self.bot(id) ?? bot
            let overCap = isOverCap(bot)
            let shouldPause = !bot.enabled || bot.schedule.days == .manual || overCap
            if let depl = bot.deploymentID, bot.deploymentPaused != shouldPause {
                try await ManagedAgentsAPI.setDeploymentPaused(depl, shouldPause)
                set(id) { $0.deploymentPaused = shouldPause }
            }
            if bot.pausedForCap != overCap { set(id) { $0.pausedForCap = overCap } }
            syncErrors[id] = nil
        } catch let error as ManagedAgentsAPI.APIError where error.status == 404 {
            // Removed in the Console: start over next time.
            set(id) { $0.agentID = nil; $0.deploymentID = nil; $0.syncedAgent = nil; $0.syncedDeployment = nil; $0.deploymentPaused = nil }
            if error.message.lowercased().contains("environment") { Self.environmentID = nil; Self.webEnvironmentID = nil }
            syncErrors[id] = "Orbit lost this bot's cloud setup and will make it again."
        } catch {
            syncErrors[id] = error.localizedDescription
        }
    }
}
