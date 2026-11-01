import AppKit
import EventKit
import SwiftUI

/// The first-run window: Orbit says hi, you try the notch, make Orbit yours, pick what you do,
/// connect your calendar and music, and you're done. Every step can be skipped.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(vm: NotchViewModel, registry: ModuleRegistry) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = OnboardingView(vm: vm, registry: registry) { [weak self] in self?.close() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: view)
        // Below the notch, so the "try it" step can point at it.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - 330, y: max(f.minY + 20, f.maxY - 520 - 140)))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Onboarding.isDone = true
                self?.window = nil
                if let o = self?.closeObserver { NotificationCenter.default.removeObserver(o) }
                self?.closeObserver = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func close() { window?.close() }
}

struct OnboardingView: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry
    let finish: () -> Void

    enum Step: Int, CaseIterable { case hello, tryIt, yours, role, connect, done }

    @State private var step: Step

    init(vm: NotchViewModel, registry: ModuleRegistry, start: Step = .hello, finish: @escaping () -> Void) {
        self.vm = vm
        self.registry = registry
        self.finish = finish
        _step = State(initialValue: start)
    }
    @State private var hovered = false
    @State private var clicked = false
    @State private var shortcut = false
    @State private var role: Onboarding.Role? = nil
    @State private var calendar: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var musicState: String? = nil
    @State private var startAtLogin = LoginItem.isInstalled
    @State private var look = Appearance.shared

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            VStack(spacing: 0) {
                dots.padding(.top, 22)
                Group {
                    switch step {
                    case .hello: hello
                    case .tryIt: tryIt
                    case .yours: yours
                    case .role: roles
                    case .connect: connect
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
                footer.padding(.horizontal, 28).padding(.bottom, 22)
            }
        }
        .frame(width: 660, height: 520)
        .foregroundStyle(.white)
        .onChange(of: vm.state) { _, s in
            if s == .peek || s == .open { hovered = true }
            if s == .open { clicked = true }
            if s == .open, vm.openedByKeyboard { shortcut = true; Onboarding.visited("shortcut") }
        }
    }

    // MARK: Steps

    private var hello: some View {
        VStack(spacing: 16) {
            OrbitView(size: 120, mood: .happy, motion: .celebrate)
                .padding(.bottom, 6)
            Text("Hi, I'm Orbit").font(.system(size: 34, weight: .bold))
            Text("I live in your notch and keep your day close: music, meetings, tasks, focus,\nfiles and your AI agents. Let me show you around. It takes a minute.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                OrbitView(size: 64, mood: .wide, motion: .nudge, gaze: CGVector(dx: 0, dy: -1))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Try the notch").font(.system(size: 26, weight: .bold))
                    Text("Up there, at the top of your screen.").foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            VStack(spacing: 10) {
                check(hovered, "Hover over the notch", "It peeks open with a glance at what's going on.")
                check(clicked, "Click it", "The full panel opens. Move the pointer away to close it.")
                check(shortcut, "Press ⌥ Space", "Opens and closes Orbit from anywhere.")
            }
        }
    }

    private var yours: some View {
        VStack(spacing: 18) {
            Text("Make me yours").font(.system(size: 26, weight: .bold))
            HStack(spacing: 12) {
                Text("What should I call you?").foregroundStyle(.white.opacity(0.7))
                TextField("Your name", text: Binding(get: { look.greetingName }, set: { look.greetingName = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Text("Pick my colour").foregroundStyle(.white.opacity(0.7)).padding(.top, 6)
            HStack(spacing: 12) {
                ForEach(Appearance.companions) { c in
                    let on = look.companionID == c.id
                    Button { look.companionID = c.id } label: {
                        VStack(spacing: 6) {
                            OrbitView(size: 52, mood: on ? .happy : .normal, motion: on ? .idle : .still, colors: c)
                            Text(c.name).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? .white : .white.opacity(0.6))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(on ? 0.14 : 0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(on ? 0.4 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(look.greetingName.isEmpty ? "Morning!" : "Morning, \(look.greetingName)!")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
        }
    }

    private var roles: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("What do you do?").font(.system(size: 26, weight: .bold))
                Text("I'll add a few add-ons to start with. Change them any time in Settings → Add-ons.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Onboarding.Role.allCases) { r in
                    let on = role == r
                    Button { role = r } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: r.symbol).font(.system(size: 15, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.white.opacity(on ? 0.25 : 0.1)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.title).font(.system(size: 14, weight: .semibold))
                                Text(names(r)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(on ? 0.16 : 0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(on ? 0.45 : 0.08), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func names(_ r: Onboarding.Role) -> String {
        r.addOns.compactMap { id in registry.addOns.first { $0.id == id }?.title }.joined(separator: ", ")
    }

    private var connect: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Connect your day").font(.system(size: 26, weight: .bold))
                Text("macOS asks before I can see anything. Skip what you don't need.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            connectRow(symbol: "calendar", tint: .red, title: "Calendar",
                       detail: calendarDetail, state: calendarState) {
                if calendar == .denied {
                    registry.module(MeetingsModule.self)?.openPrivacySettings()
                } else {
                    registry.module(MeetingsModule.self)?.requestAccess()
                    pollCalendar()
                }
            }
            if Onboarding.outlookInstalled || calendar == .fullAccess {
                connectRow(symbol: "envelope.fill", tint: .blue, title: "Outlook or Google calendar",
                           detail: "If your work calendar lives in Outlook or Google, add the account in Internet Accounts so I can see it.",
                           state: .action("Open Internet Accounts")) { Onboarding.openInternetAccounts() }
            }
            connectRow(symbol: "music.note", tint: .green, title: "Spotify or Music",
                       detail: musicState ?? "Show what's playing, with play, pause and skip.",
                       state: musicState == nil ? .action("Allow") : .done) {
                Task {
                    let asked = await Onboarding.requestMusicPermission()
                    musicState = asked ? "Ready. Music shows in the notch while it plays." : "Open Spotify or Music once, and I'll ask then."
                }
            }
            connectRow(symbol: "sparkles", tint: .purple, title: "HubSpot and Claude",
                       detail: "Tasks from HubSpot and Smart Ask. Add your keys later in Settings → Accounts.",
                       state: .action("Later")) {}
                .opacity(0.75)
        }
    }

    private enum RowState: Equatable { case action(String), done }

    private var calendarState: RowState {
        switch calendar {
        case .fullAccess: .done
        case .denied, .restricted: .action("Open Settings")
        default: .action("Allow")
        }
    }

    private var calendarDetail: String {
        switch calendar {
        case .fullAccess: "Your next meeting and its Join button show in the notch."
        case .denied, .restricted: "Calendar access is off. Turn on Orbit in Privacy & Security → Calendars."
        default: "Your next meeting and a one-click Join for Zoom, Teams, Meet and Webex."
        }
    }

    private func pollCalendar() {
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                calendar = EKEventStore.authorizationStatus(for: .event)
                if calendar != .notDetermined { break }
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            OrbitView(size: 110, mood: .happy, motion: .celebrate)
            Text("You're all set\(look.greetingName.isEmpty ? "" : ", \(look.greetingName)")!").font(.system(size: 30, weight: .bold))
            Text("Hover the notch any time, or press ⌥ Space. Add-ons live in the grid tab,\nand Settings are behind the gear.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            Toggle("Start Orbit when I log in", isOn: $startAtLogin)
                .toggleStyle(.switch)
                .disabled(!LoginItem.isInstalled)
                .padding(.top, 6)
            if !LoginItem.isInstalled {
                Text("Move Orbit to Applications to start it at login.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: Pieces

    private func check(_ on: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20)).foregroundStyle(on ? Color.green : .white.opacity(0.35))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(on ? 0.1 : 0.05)))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: on)
    }

    private func connectRow(symbol: String, tint: Color, title: String, detail: String, state: RowState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .done:
                Label("Done", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
            case .action(let t):
                Button(t, action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule().fill(.white.opacity(s == step ? 0.9 : s.rawValue < step.rawValue ? 0.45 : 0.15))
                    .frame(width: s == step ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .hello && step != .done {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if step != .done {
                Button("Skip setup") { complete() }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).padding(.trailing, 10)
            }
            Button {
                if step == .done { complete() } else { go(1) }
            } label: {
                Text(primaryTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .hello: "Let's go"
        case .tryIt: hovered && clicked && shortcut ? "Nice! Continue" : "Continue"
        case .role: role == nil ? "Not now" : "Add these"
        case .done: "Open Orbit"
        default: "Continue"
        }
    }

    private func go(_ by: Int) {
        if step == .role, by > 0, let role { Onboarding.apply(role, to: registry) }
        guard let next = Step(rawValue: step.rawValue + by) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { step = next }
    }

    private func complete() {
        if startAtLogin, LoginItem.isInstalled, !LoginItem.isEnabled { _ = LoginItem.set(true) }
        Onboarding.isDone = true
        finish()
        vm.selectedTab = "home"
        vm.state = .open
    }
}

/// The dark, colourful wallpaper behind onboarding (like the app's glass panels).
struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.09)
            Circle().fill(Color(red: 0.36, green: 0.24, blue: 0.96)).frame(width: 520).blur(radius: 110).offset(x: -260, y: 220).opacity(0.7)
            Circle().fill(Color(red: 1, green: 0.42, blue: 0.24)).frame(width: 380).blur(radius: 120).offset(x: 280, y: -200).opacity(0.5)
            Circle().fill(Color(red: 0.12, green: 0.71, blue: 1)).frame(width: 360).blur(radius: 110).offset(x: 300, y: 260).opacity(0.45)
            Rectangle().fill(.ultraThinMaterial).opacity(0.35)
        }
        .ignoresSafeArea()
    }
}
