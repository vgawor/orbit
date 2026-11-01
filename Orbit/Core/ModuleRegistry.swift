import SwiftUI

/// Holds every module and which ones are turned on (saved in UserDefaults).
@MainActor
@Observable
final class ModuleRegistry {
    let all: [any NotchModule]
    private(set) var enabledIDs: Set<String>

    /// Stores what's turned off, so modules added in later versions start switched on.
    private static let disabledKey = "disabledModules"
    /// Add-ons are the other way round: off until you add them (Settings → Add-ons).
    private static let addOnsKey = "enabledAddOns"

    /// Tabs pinned to the tab bar, in order. Everything else with a tab opens from the Add-ons tab.
    private(set) var pinnedIDs: [String]
    private static let pinnedKey = "pinnedTabs"
    /// How many pinned tabs fit in the bar; more pins wait in the Add-ons tab.
    nonisolated static let maxPinned = 8

    init(modules: [any NotchModule]) {
        all = modules
        pinnedIDs = UserDefaults.standard.stringArray(forKey: Self.pinnedKey)
            ?? Array(modules.filter { !($0 is any AddOnModule) && $0.showsTab }.map(\.id).prefix(Self.maxPinned))
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        let addOns = Set(UserDefaults.standard.stringArray(forKey: Self.addOnsKey) ?? [])
        enabledIDs = Set(modules.filter { !($0 is any AddOnModule) }.map(\.id)).subtracting(disabled)
            .union(modules.filter { $0 is any AddOnModule && addOns.contains($0.id) }.map(\.id))
        // ORBIT_PREVIEW=1 (used for layout snapshots) starts nothing, so no permission prompts appear.
        if !Self.isPreview { enabled.forEach { $0.start() } }
    }

    static var isPreview: Bool { ProcessInfo.processInfo.environment["ORBIT_PREVIEW"] == "1" }

    func module<T: NotchModule>(_ type: T.Type) -> T? { all.lazy.compactMap { $0 as? T }.first }

    /// Turned on, and allowed by your plan (Pro add-ons need Pro).
    var enabled: [any NotchModule] { all.filter { enabledIDs.contains($0.id) && allowed($0) } }

    var addOns: [any AddOnModule] { all.compactMap { $0 as? any AddOnModule } }

    func allowed(_ module: any NotchModule) -> Bool {
        guard let addOn = module as? any AddOnModule else { return true }
        return Entitlements.shared.allows(addOn.addOn.tier)
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) && all.first { $0.id == id }.map(allowed) != false }

    /// Layout snapshots only: turns add-ons on without saving or starting them.
    func previewEnable(_ ids: [String]) { enabledIDs.formUnion(ids) }

    /// The most important thing that needs you right now, if anything.
    /// Everything that wants you, most important first (snoozed ones included).
    var attentions: [Attention] { enabled.compactMap(\.attention).sorted { $0.priority > $1.priority } }
    /// The most important thing that wants you and isn't snoozed.
    var topAttention: Attention? { attentions.first { !NudgeSnoozes.shared.isSnoozed($0.id) } }

    // MARK: Tabs

    /// Everything turned on that has a tab.
    var tabModules: [any NotchModule] { enabled.filter(\.showsTab) }
    /// The tabs shown in the tab bar.
    var pinnedTabs: [any NotchModule] {
        Array(pinnedIDs.compactMap { id in tabModules.first { $0.id == id } }.prefix(Self.maxPinned))
    }
    /// The tabs that open from the Add-ons tab instead.
    var launcherTabs: [any NotchModule] {
        let pinned = Set(pinnedTabs.map(\.id))
        return tabModules.filter { !pinned.contains($0.id) }
    }

    func isPinned(_ id: String) -> Bool { pinnedTabs.contains { $0.id == id } }

    /// True when the tab bar has no room for another pin.
    var pinsFull: Bool { pinnedTabs.count >= Self.maxPinned }

    /// Pins or unpins a tab. Pinning does nothing when the bar is full (unpin one first).
    @discardableResult
    func setPinned(_ id: String, _ on: Bool) -> Bool {
        if on {
            guard !isPinned(id) else { return true }
            guard !pinsFull else { return false }
            // Pins of things that are turned off don't count; tidy them away.
            let live = Set(tabModules.map(\.id))
            pinnedIDs.removeAll { $0 == id || !live.contains($0) }
            pinnedIDs.append(id)
        } else {
            pinnedIDs.removeAll { $0 == id }
        }
        UserDefaults.standard.set(pinnedIDs, forKey: Self.pinnedKey)
        return true
    }

    /// Moves a pinned tab one step left (-1) or right (+1).
    func movePinned(_ id: String, by step: Int) {
        guard let i = pinnedIDs.firstIndex(of: id) else { return }
        let j = i + step
        guard pinnedIDs.indices.contains(j) else { return }
        pinnedIDs.swapAt(i, j)
        UserDefaults.standard.set(pinnedIDs, forKey: Self.pinnedKey)
    }

    /// Drag to reorder: puts `id` where `target` is (the others shift over).
    func movePinned(_ id: String, to target: String) {
        guard id != target, let from = pinnedIDs.firstIndex(of: id), let to = pinnedIDs.firstIndex(of: target) else { return }
        pinnedIDs.remove(at: from)
        pinnedIDs.insert(id, at: to)
        UserDefaults.standard.set(pinnedIDs, forKey: Self.pinnedKey)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let module = all.first(where: { $0.id == id }) else { return }
        if on { enabledIDs.insert(id); module.start() } else { enabledIDs.remove(id); module.stop() }
        let disabled = all.filter { !($0 is any AddOnModule) }.map(\.id).filter { !enabledIDs.contains($0) }
        UserDefaults.standard.set(disabled, forKey: Self.disabledKey)
        let addOns = all.filter { $0 is any AddOnModule }.map(\.id).filter { enabledIDs.contains($0) }
        UserDefaults.standard.set(addOns, forKey: Self.addOnsKey)
    }

    /// The modules Orbit ships with. Placeholders are replaced phase by phase.
    static func makeDefault(alerts: AlertCenter, openPanel: @escaping @MainActor (String) -> Void,
                            closePanel: @escaping @MainActor () -> Void = {},
                            setPresenting: @escaping @MainActor (Bool) -> Void = { _ in }) -> ModuleRegistry {
        let music = MusicModule()
        let meetings = MeetingsModule(alerts: alerts)
        let tasks = TasksModule(openPanel: openPanel)
        let focus = FocusModule(alerts: alerts, music: music)
        let notes = NotesModule(openPanel: openPanel)
        let shelf = ShelfModule()
        let draw = DrawModule()
        // Ask: a command bar that can start timers, add tasks and notes, control music, join meetings…
        let ask = AskModule(actions: AskActions(
            startTimer: { minutes in focus.startTimer(minutes); openPanel(focus.id) },
            addTask: { tasks.add($0) },
            addNote: { text in
                notes.add()
                if let id = notes.selectedID { notes.update(id, body: text) }
            },
            playPauseMusic: { music.send(.playPause) },
            nextTrack: { music.send(.next) },
            joinNextMeeting: { if let m = meetings.next { meetings.join(m) } },
            nextMeetingTitle: { meetings.next.flatMap { $0.link == nil ? nil : $0.title } },
            openTab: { openPanel($0) }
        ))
        let capture = CaptureModule(shelf: shelf, alerts: alerts,
                                    startDrawing: { draw.controller.start() }, closePanel: closePanel)
        // Smart Ask: Claude with Orbit's actions as tools (also writes the morning brief and meeting prep).
        var registryRef: ModuleRegistry?
        let smart = SmartAssistant(music: music, meetings: meetings, tasks: tasks, focus: focus, notes: notes,
                                   agents: { registryRef?.module(AgentsModule.self) }, openPanel: openPanel,
                                   setPresenting: setPresenting)
        ask.smart = smart
        let agents = AgentsModule(alerts: alerts)
        agents.smart = smart
        // Bots: AI teammates in the cloud that come back to you in the notch.
        let bots = BotsModule(tools: smart.orbitTools, meetings: meetings, alerts: alerts, openPanel: openPanel)
        // The first eight with a tab show as icons; the rest go in the More menu.
        let registry = ModuleRegistry(modules: [
            music, meetings, tasks, focus, notes, shelf, capture,
            agents,
            bots,
            ask,
            YouTubeModule(openPanel: openPanel),
            PrompterModule(),
            MirrorModule(),
            MicModule(alerts: alerts),
            SSHModule(),
            PhotosModule(),
            draw,
            smart,
        ] + AddOnCatalog.make(AddOnContext(
            alerts: alerts, openPanel: openPanel, closePanel: closePanel,
            addTask: { title, due in
                tasks.addLocal(LocalTaskForm.makeTask(title: title, due: due, hasTime: false, priority: "NONE", link: "", notes: ""))
            },
            addNote: { text in
                notes.add()
                if let id = notes.selectedID { notes.update(id, body: text) }
            })))
        registryRef = registry
        return registry
    }
}
