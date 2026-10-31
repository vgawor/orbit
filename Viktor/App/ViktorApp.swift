import Carbon.HIToolbox
import SwiftUI
import ViktorKit

/// Starts the app. Copies settings from the app's earlier identity first (see LegacySettings).
@main
enum OrbitMain {
    static func main() {
        LegacySettings.migrate()
        if !ModuleRegistry.isPreview { MainActor.assumeIsolated { Onboarding.markDoneIfReturningUser() } }
        ViktorApp.main()
    }
}

struct ViktorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open Orbit  ⌥Space") { delegate.vm.toggleFromKeyboard() }
            Button(delegate.vm.presenting ? "Stop presenting  ⌥P" : "Presenting mode  ⌥P") { delegate.vm.presenting.toggle() }
            Button("Mute / unmute mic  ⌥M") { delegate.registry.module(MicModule.self)?.toggleMute() }
            Button("Take a screenshot (area)") { delegate.registry.module(CaptureModule.self)?.screenshot(.area) }
            Button("Draw on screen  ⌃⌥D") { delegate.registry.module(DrawModule.self)?.toggle() }
            Button("Test alert") { delegate.postTestAlert() }
            Divider()
            Button("Check for updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.isAvailable)
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Orbit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: OrbitMenuIcon.image)
        }

        Settings {
            SettingsView(registry: delegate.registry, delegate: delegate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vm = NotchViewModel()
    let alerts = AlertCenter()
    lazy var registry = ModuleRegistry.makeDefault(
        alerts: alerts,
        openPanel: { [weak self] tab in
            self?.vm.selectedTab = tab
            if self?.vm.state != .open { self?.vm.state = .open }
        },
        closePanel: { [weak self] in self?.vm.close() },
        setPresenting: { [weak self] on in self?.vm.presenting = on })
    private var controller: NotchWindowController?
    private var hotKeys: [HotKey] = []
    private var nudgeTimer: Timer?
    /// Local API for the viktor CLI, Claude Code hooks and your own scripts.
    private(set) var api: LocalAPIServer?

    /// orbit:// links, e.g. the sign-in link in Orbit's account email (orbit://auth-callback#access_token=…).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "orbit" {
            Task { await OrbitCloud.shared.handle(url) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Opened from the DMG or Downloads: offer to move to Applications (relaunches from there).
        if AppMover.offerIfNeeded() { return }
        Updater.shared.start()
        controller = NotchWindowController(vm: vm, registry: registry, alerts: alerts)
        SettingsWindow.closeNotch = { [weak self] in self?.vm.close() }
        SettingsWindow.notchHeight = { [weak self] in (self?.vm.maxSize.height ?? 0) + (self?.vm.floatGap ?? 0) }
        // ⌥Space opens/closes, ⌥P toggles Presenting.
        hotKeys.append(HotKey { [weak self] in
            MainActor.assumeIsolated { self?.vm.toggleFromKeyboard() }
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.vm.presenting.toggle() }
        })
        // ⌥K opens Ask (the command bar).
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.vm.selectedTab = "ask"
                if self.vm.state != .open { self.vm.toggleFromKeyboard() }
            }
        })
        // ⌥M mutes/unmutes the mic, ⌃⌥D starts/stops screen drawing.
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.registry.module(MicModule.self)?.toggleMute() }
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | controlKey)) { [weak self] in
            MainActor.assumeIsolated { self?.registry.module(DrawModule.self)?.toggle() }
        })
        alerts.isSuppressed = { [weak self] in
            MainActor.assumeIsolated { self?.vm.presenting ?? false }
        }

        // Tokens: move any old file into the Keychain (once), then read them into memory, all off the
        // main thread so a Keychain permission prompt can't freeze the notch.
        if !ModuleRegistry.isPreview { Thread.detachNewThread { [weak self] in
            _ = Secrets.migrateFromFile()
            Secrets.warmUp(["hubspot", "github", "anthropic", SpotifyConnect.keychainAccount])
            Task { @MainActor in
                SpotifyConnect.shared.refreshState()
                await self?.registry.module(TasksModule.self)?.reload()
                await self?.registry.module(AgentsModule.self)?.github.refresh()
            }
        } }

        // Every couple of seconds: is there something Dot should point at?
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.vm.updateNudge(self.registry.topAttention)
            }
        }

        let args = CommandLine.arguments
        if let agents = registry.module(AgentsModule.self), !args.contains("--snapshot"), !args.contains("--convert") {
            let meetings = registry.module(MeetingsModule.self)
            let server = LocalAPIServer(token: APIConfig.loadOrCreateToken()) { req in
                if req.path == "/v1/debug/meetings", let meetings {
                    return .json(await meetings.debugLinks())
                }
                return await agents.handle(req)
            }
            server.start()
            api = server
        }

        // First launch: the welcome tour.
        if !Onboarding.isDone, !ModuleRegistry.isPreview, !args.contains("--snapshot"), !args.contains("--convert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                OnboardingWindow.shared.show(vm: self.vm, registry: self.registry)
            }
        }

        // Test flags: `open Orbit.app --args --open` or `--alert`
        if args.contains("--open") { vm.toggleFromKeyboard() }
        if args.contains("--alert") { postTestAlert() }
        // `--convert <file> <png|jpeg|heic|tiff|pdf|mp4|m4a>`: converts one file, prints the result, quits.
        if let i = args.firstIndex(of: "--convert"), i + 2 < args.count,
           let format = FileConverter.Format(rawValue: args[i + 2]) {
            let url = URL(fileURLWithPath: args[i + 1])
            Task {
                do { print("OK", try await FileConverter.convert(url, to: format).path) } catch { print("FAIL", error.localizedDescription) }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            // Give modules (music, calendar) a moment to load real data first.
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                await registry.module(TasksModule.self)?.reload()
                snapshot(to: dir)
            }
        }
    }

    /// Renders the open panel and the alert to PNGs, then quits. Used to check layout without screen recording.
    private func snapshot(to dir: String) {
        if CommandLine.arguments.contains("--orbit-film") { orbitFilm(to: dir); NSApp.terminate(nil); return }
        let size = CGSize(width: vm.maxSize.width + 80, height: vm.maxSize.height + 40 + vm.floatGap)
        var shots: [(String, NotchState, String)] = [("peek", .peek, "home"), ("alert", .alert, "home"), ("drop", .drop, "home"), ("open-home", .open, "home")]
        shots += registry.enabled.map { ("open-\($0.id)", .open, $0.id) }
        let tasks = registry.module(TasksModule.self)
        if let first = tasks?.items.first(where: { $0.source == "hubspot" }) ?? tasks?.items.first {
            tasks?.selectedID = first.id
            shots.append(("open-task-detail", .open, "tasks"))
        }
        // The HubSpot task form, started from typed text. Rendered last; it doesn't touch HubSpot.
        var formShot: (() -> Void)?
        if let tasks, tasks.hubSpotConnected {
            formShot = { tasks.selectedID = nil; tasks.composing = "Send offer to Northwind tomorrow 14:00" }
        }
        if formShot != nil { shots.append(("open-task-form", .open, "tasks")) }
        if tasks != nil { shots.append(("open-task-new", .open, "tasks")) }
        // Add-ons: one picture each (they're off by default, so turn them on for the snapshot only).
        registry.previewEnable(registry.addOns.map(\.id))
        shots += registry.addOns.map { ("addon-\($0.id)", .open, $0.id) }
        shots.append(("open-launcher", .open, AddOnsLauncher.tabID))
        shots.append(("open-home-addons", .open, "home"))
        let agents = registry.module(AgentsModule.self)
        if agents != nil { shots += [("open-agents-new", .open, "agents"), ("open-agents-orbit", .open, "agents"), ("open-agents-chat", .open, "agents")] }
        for (name, state, tab) in shots {
            if name == "open-task-form" { formShot?() }
            if name == "open-task-new" {
                tasks?.composing = nil; tasks?.selectedID = nil
                tasks?.composingLocal = "Call Anna tomorrow 10:00"
            }
            if name == "open-agents-new" { agents?.selection = "new" }
            if name == "open-agents-orbit" { agents?.selection = "orbit" }
            if name == "open-agents-chat", let run = agents?.runner.addPreviewRun() { agents?.selection = run.id }
            if state == .alert { postTestAlert() }
            vm.state = state
            vm.selectedTab = tab
            let view = NotchRootView(vm: vm, registry: registry, alerts: alerts)
                .frame(width: size.width, height: size.height)
                .background(SnapshotWallpaper())
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        // Each add-on's Home widget on its own, at Home-card width.
        for addOn in registry.addOns {
            guard let card = addOn.homeCard else { continue }
            let view = card.frame(width: 420).padding(20).background(SnapshotWallpaper()).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("home-\(addOn.id).png"))
            }
        }
        // Spotify Connect devices and the Outlook hint.
        SpotifyConnect.shared.previewFill()
        registry.module(MeetingsModule.self)?.previewHints()
        let bots = registry.module(BotsModule.self)
        bots?.previewFill()
        let extras: [(String, AnyView)] = [
            ("bots-panel", AnyView(bots.map { AnyView(BotsPanel(module: $0)) }.frame(width: 700, height: 320))),
            ("bots-home-card", AnyView(bots.flatMap { m in m.runner.unread.first.map { AnyView(BotReportCard(module: m, run: $0, compact: true)) } }.frame(width: 340))),
            ("bots-home-approval", AnyView(bots.flatMap { m in m.runner.approvals.first.map { AnyView(ApprovalCard(module: m, approval: $0, compact: true)) } }.frame(width: 340))),
            ("bots-team", AnyView(bots.map { AnyView(TeamActivity(module: $0)) }.frame(width: 470, height: 260))),
            ("bots-approval", AnyView(bots.flatMap { m in m.store.bot(Bot.accountManager.id).map { AnyView(BotDetail(module: m, bot: $0)) } }.frame(width: 470, height: 420))),
            ("spotify-devices", AnyView(NotchCard { SpotifyDevicesView {} }.frame(width: 700, height: 300))),
            ("meetings-hint", AnyView(registry.module(MeetingsModule.self).map { AnyView(AgendaView(module: $0)) }.frame(width: 700, height: 300))),
        ]
        for (name, view) in extras {
            let r = ImageRenderer(content: view.padding(20).background(SnapshotWallpaper()).environment(\.colorScheme, .dark)); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        // The welcome tour, one picture per step.
        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(vm: vm, registry: registry, start: step) {}.environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(step.rawValue).png"))
            }
        }
        // Orbit's moods and motions, enlarged, in every colour, to check how they read.
        let sheet = VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ForEach(OrbitView.Mood.allCases, id: \.self) { mood in
                    VStack { OrbitView(size: 96, mood: mood, motion: .still); Text(mood.rawValue).foregroundStyle(.white) }
                }
            }
            HStack(spacing: 16) {
                ForEach(OrbitView.Motion.allCases, id: \.self) { motion in
                    VStack { OrbitView(size: 72, motion: motion); Text(motion.rawValue).foregroundStyle(.white) }
                }
            }
            HStack(spacing: 16) {
                ForEach(Appearance.companions) { c in
                    VStack { OrbitView(size: 72, motion: .still, colors: c); Text(c.name).foregroundStyle(.white) }
                }
            }
        }.padding(24).background(Color(white: 0.1))
        let r = ImageRenderer(content: sheet); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("orbit-sheet.png"))
        }
        NSApp.terminate(nil)
    }

    /// Orbit over time, one frame every 0.2 s, to check how its motion reads.
    private func orbitFilm(to dir: String) {
        for motion in [OrbitView.Motion.idle, .working] {
            let film = VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<10, id: \.self) { col in
                            OrbitView(size: 100, motion: motion, time: 1000.5 + Double(row * 10 + col) * 0.12)
                        }
                    }
                }
            }.padding(12).background(Color(white: 0.12))
            let r = ImageRenderer(content: film); r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("orbit-film-\(motion.rawValue).png"))
            }
        }
    }

    func postTestAlert() {
        alerts.post(NotchAlert(
            symbol: "video.fill", tint: Tokens.zoom,
            title: "Design review starts in 2 min",
            subtitle: "Zoom · this is a test alert",
            actions: [.init(title: "Later"), .init(title: "Join", isPrimary: true)]
        ))
    }
}

/// A colourful stand-in wallpaper for layout snapshots, so glass surfaces show up.
private struct SnapshotWallpaper: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.09)
            Circle().fill(Color(red: 0.36, green: 0.24, blue: 0.96)).frame(width: 700).blur(radius: 120).offset(x: -380, y: 260)
            Circle().fill(Color(red: 1, green: 0.42, blue: 0.24)).frame(width: 560).blur(radius: 130).offset(x: 360, y: -160)
            Circle().fill(Color(red: 0.12, green: 0.71, blue: 1)).frame(width: 520).blur(radius: 120).offset(x: 420, y: 380)
        }
    }
}
