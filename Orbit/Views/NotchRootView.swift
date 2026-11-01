import SwiftUI

/// The black shape at the top of the screen and everything inside it.
struct NotchRootView: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry
    let alerts: AlertCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Closed and peek stay pure black (they are the notch). Panels below it are glass.
                // Without a hardware notch there's nothing to blend into, so it's glass all the way.
                if [.open, .alert, .drop].contains(vm.state) {
                    PanelBackground(blackTop: vm.hasHardwareNotch ? vm.notchSize.height + 6 : 0)
                } else if !vm.hasHardwareNotch {
                    PanelBackground(blackTop: 0)
                } else {
                    Color.black
                }

                content
                    .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.1)))
            }
            .frame(width: vm.currentSize.width, height: vm.currentSize.height)
            // Hanging from the notch: only the bottom corners are round. Floating (no notch): all four.
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: vm.hasHardwareNotch ? 0 : min(vm.bottomRadius, vm.currentSize.height / 2),
                                              bottomLeadingRadius: vm.bottomRadius,
                                              bottomTrailingRadius: vm.bottomRadius,
                                              topTrailingRadius: vm.hasHardwareNotch ? 0 : min(vm.bottomRadius, vm.currentSize.height / 2),
                                              style: .continuous))
            .overlay {
                if !vm.hasHardwareNotch {
                    UnevenRoundedRectangle(topLeadingRadius: min(vm.bottomRadius, vm.currentSize.height / 2),
                                           bottomLeadingRadius: vm.bottomRadius, bottomTrailingRadius: vm.bottomRadius,
                                           topTrailingRadius: min(vm.bottomRadius, vm.currentSize.height / 2), style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity([.open, .alert, .drop].contains(vm.state) ? 0.45 : 0), radius: 24, y: 12)
            // On screens without a notch there's nothing to blend into, so the closed pill is invisible.
            // It still reacts to the pointer at the top center of the screen.
            .opacity(vm.state == .closed && !vm.hasHardwareNotch && !vm.showPillWithoutNotch ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if vm.state == .peek || vm.state == .closed { vm.state = .open }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, vm.floatGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // After a moment of peeking, a black dot appears and tugs the pill.
        .overlay(alignment: .top) {
            if vm.companionFlight && !reduceMotion { PeekDot(vm: vm) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(Tokens.spring, value: vm.state)
        .animation(Tokens.spring, value: vm.notchSize)
    }

    @ViewBuilder private var content: some View {
        switch vm.state {
        case .closed:
            EmptyView()
        case .peek:
            if vm.presenting { PresentingPeek(vm: vm) } else { PeekView(vm: vm, registry: registry) }
        case .open:
            OpenPanelView(vm: vm, registry: registry)
        case .drop:
            if vm.dragKind == .link, let youtube = registry.module(YouTubeModule.self) {
                LinkDropView(vm: vm, youtube: youtube)
            } else if let shelf = registry.module(ShelfModule.self) {
                DropZonesView(vm: vm, shelf: shelf)
            }
        case .alert:
            if let alert = alerts.current {
                AlertView(alert: alert, topInset: vm.notchSize.height) { alerts.dismiss() }
            }
        }
    }
}

/// Widened pill: glances on either side of the hardware notch, and a row of info chips below.
struct PeekView: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry

    /// The winning glance for a side, and the module it belongs to.
    private func glance(_ side: PeekSide) -> (view: AnyView, owner: String)? {
        registry.enabled
            .filter { $0.peekSide == side }
            .compactMap { m in m.peekView.map { (m.peekPriority, $0, m.id) } }
            .max { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    private var chips: [PeekChip] {
        let all = registry.enabled.compactMap { m -> PeekChip? in
            guard var c = m.peekChip else { return nil }
            if c.target == nil { c.target = m.id }
            return c
        }.sorted { $0.priority > $1.priority }
        if all.isEmpty {
            return [PeekChip(symbol: "calendar", text: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                             tint: Tokens.secondary, priority: 0, target: "meetings")]
        }
        return Array(all.prefix(3))
    }

    /// Opens the notch on a feature's page.
    private func open(_ tab: String?) {
        if let tab { vm.selectedTab = tab }
        vm.state = .open
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let g = glance(.leading) {
                        g.view.contentShape(Rectangle()).onTapGesture { open(g.owner) }
                    } else {
                        Text(Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    }
                }
                .frame(width: vm.peekExtra - 16, alignment: .leading)
                Spacer(minLength: vm.notchSize.width)
                Group {
                    if let g = glance(.trailing) {
                        g.view.contentShape(Rectangle()).onTapGesture { open(g.owner) }
                    } else {
                        OrbitButton(size: 32) { open("ask") }
                    }
                }
                .frame(width: vm.peekExtra - 16, alignment: .trailing)
            }
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .frame(height: vm.notchSize.height + vm.peekDrop)

            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Button { open(chip.target) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chip.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(chip.tint)
                            Text(chip.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Tokens.surface2))
                        .frame(maxWidth: 170)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: vm.peekChips - 4, alignment: .top)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
    }
}

/// The full panel: status + icons on top, a row of tabs, then the selected page.
struct OpenPanelView: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            tabBar
            Group {
                if vm.presenting {
                    PresentingPanel(vm: vm)
                } else if vm.selectedTab == "home" {
                    HomeView(vm: vm, registry: registry)
                } else if vm.selectedTab == AddOnsLauncher.tabID {
                    AddOnsLauncher(vm: vm, registry: registry)
                } else if let module = registry.enabled.first(where: { $0.id == vm.selectedTab }) {
                    module.panel
                } else if vm.selectedTab == "ask", let ask = registry.module(AskModule.self) {
                    // Ask (Smart Ask) always opens from Dot, 🔍 or ⌥K, even if its tab is switched off.
                    ask.panel
                } else {
                    HomeView(vm: vm, registry: registry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
        }
        .padding(.top, max(vm.notchSize.height, 30) + 6)
        .padding([.horizontal, .bottom], 18)
        .background { if Appearance.shared.panelStyle == .solid { DottedBackground() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            StatusLine(vm: vm, registry: registry)
            Spacer(minLength: 8)
            headerIcon(vm.selectedTab == "ask" ? "magnifyingglass.circle.fill" : "magnifyingglass",
                       on: vm.selectedTab == "ask", help: "Ask: type a command (⌥K)") { vm.selectedTab = "ask" }
            if let mic = registry.module(MicModule.self), registry.isEnabled(mic.id) {
                headerIcon(mic.isMuted ? "mic.slash.fill" : "mic", on: mic.isMuted, tint: mic.isMuted ? Tokens.error : nil,
                           help: mic.isMuted ? "Unmute mic (⌥M)" : "Mute mic (⌥M)") { mic.toggleMute() }
            }
            headerIcon(vm.presenting ? "eye.slash.fill" : "eye.slash", on: vm.presenting, tint: vm.presenting ? Tokens.attention : nil,
                       help: vm.presenting ? "Stop presenting (⌥P)" : "Presenting: hide notch content and pop-ups (⌥P)") {
                vm.presenting.toggle()
            }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .glassSurface(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { SettingsWindow.willOpen() })
            .help("Settings")
        }
    }

    private func headerIcon(_ symbol: String, on: Bool, tint: Color? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(tint ?? (on ? .white : .white.opacity(0.85)))
                .frame(width: 30, height: 30)
                .glassSurface(Circle(), selected: on, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Tabs

    @Namespace private var tabSpace

    /// A floating glass bar; the selected tab's bright capsule slides between tabs.
    private var tabBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            tabs
                .padding(4)
                .glassSurface(Capsule())
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: vm.selectedTab)
            Spacer(minLength: 0)
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            TabButton(title: "Home", symbol: "square.grid.2x2.fill", selected: vm.selectedTab == "home", space: tabSpace) { vm.selectedTab = "home" }
            // Pinned tabs; everything else opens from the Add-ons tab (pin and unpin there or in Settings → Add-ons).
            // Right-click a tab to move it left or right, or unpin it.
            ForEach(registry.pinnedTabs, id: \.id) { module in
                TabButton(title: module.title, symbol: module.symbol, selected: vm.selectedTab == module.id, space: tabSpace) {
                    vm.selectedTab = module.id
                }
                .contextMenu {
                    Button("Move left") { registry.movePinned(module.id, by: -1) }
                        .disabled(registry.pinnedTabs.first?.id == module.id)
                    Button("Move right") { registry.movePinned(module.id, by: 1) }
                        .disabled(registry.pinnedTabs.last?.id == module.id)
                    Divider()
                    Button("Unpin from tab bar") { registry.setPinned(module.id, false) }
                }
            }
            // An unpinned add-on that's open shows as a tab while it's open.
            if let current = registry.launcherTabs.first(where: { $0.id == vm.selectedTab }) {
                TabButton(title: current.title, symbol: current.symbol, selected: true, space: tabSpace) {}
                    .contextMenu { pinButton(current.id) }
            }
            TabButton(title: "Add-ons", symbol: "square.grid.3x3.fill", selected: vm.selectedTab == AddOnsLauncher.tabID, space: tabSpace) {
                vm.selectedTab = AddOnsLauncher.tabID
            }
        }
    }

    @ViewBuilder private func pinButton(_ id: String) -> some View {
        if registry.pinsFull {
            Text("Tab bar is full: unpin a tab first")
        } else {
            Button("Pin to tab bar") { registry.setPinned(id, true) }
        }
    }
}

/// Top-left of the panel: what matters most right now ("All clear", "Meeting in 4 min", "Claude needs you"…).
struct StatusLine: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry

    var body: some View {
        let (text, tint) = status
        HStack(spacing: 9) {
            // Orbit leads the status line, acting out what's going on. Click it to ask anything.
            OrbitButton(size: 36, motion: orbitMotion, mood: orbitMood, tint: registry.topAttention?.tint ?? Tokens.attention) { vm.selectedTab = "ask" }
                .contextMenu {
                    if let a = registry.topAttention { SnoozeMenuItems(attention: a) }
                    else if NudgeSnoozes.shared.hasActive() {
                        Button("Show snoozed reminders again") { NudgeSnoozes.shared.wakeAll() }
                    }
                }
            // Click the status: everything that needs you or is running, each one a click away.
            Menu {
                statusMenu
            } label: {
                HStack(spacing: 4) {
                    Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(tint.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What needs you")
        }
    }

    /// The modules that want you (snoozed ones last) and the ones that are running.
    @ViewBuilder private var statusMenu: some View {
        let snoozes = NudgeSnoozes.shared
        let wanting = registry.enabled.compactMap { m in m.attention.map { (m, $0) } }
            .sorted { $0.1.priority > $1.1.priority }
        let active = wanting.filter { !snoozes.isSnoozed($0.1.id) }
        let snoozed = wanting.filter { snoozes.isSnoozed($0.1.id) }
        let running = registry.enabled.filter { $0.runningCount > 0 }
        if active.isEmpty && running.isEmpty {
            Text("Nothing needs you right now")
        }
        if !active.isEmpty {
            Section("Needs you") {
                ForEach(active, id: \.1.id) { m, a in
                    Button { open(m.id) } label: { Label(a.headline ?? a.label, systemImage: a.symbol) }
                }
            }
        }
        if !running.isEmpty {
            Section("Running") {
                ForEach(running, id: \.id) { m in
                    Button { open(m.id) } label: { Label("\(m.title) · \(m.runningCount) running", systemImage: m.symbol) }
                }
            }
        }
        if !snoozed.isEmpty {
            Section("Snoozed") {
                ForEach(snoozed, id: \.1.id) { m, a in
                    Button { open(m.id) } label: { Label(a.headline ?? a.label, systemImage: "bell.slash") }
                }
            }
        }
        if let first = active.first {
            Divider()
            Menu("Snooze “\(first.1.headline ?? first.1.label)”") {
                ForEach(SnoozeOption.allCases) { option in
                    Button(option.title) { snoozes.snooze(first.1.id, option) }
                }
            }
        }
        if snoozes.hasActive() {
            Button("Show snoozed reminders again") { snoozes.wakeAll() }
        }
    }

    private func open(_ id: String) {
        // Modules without a tab of their own (like Smart Ask) open on Home.
        vm.selectedTab = registry.tabModules.contains { $0.id == id } ? id : "home"
    }

    /// Orbit acts out the status: nudges when something needs you, works while things run.
    private var orbitMotion: OrbitView.Motion {
        if vm.presenting { return .sleep }
        if let a = registry.topAttention { return a.tint == Tokens.error ? .alert : .glow }
        if registry.enabled.contains(where: { $0.runningCount > 0 }) { return .working }
        return .idle
    }
    private var orbitMood: OrbitView.Mood {
        registry.topAttention != nil ? .wide : .normal
    }

    private var status: (String, Color) {
        if vm.presenting { return ("Presenting", Tokens.attention) }
        if let a = registry.topAttention { return (a.headline ?? a.label, a.tint) }
        let running = registry.enabled.reduce(0) { $0 + $1.runningCount }
        if running > 0 { return ("\(running) running", Tokens.live) }
        return ("All clear", Tokens.secondary)
    }
}

struct TabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                // Only the selected tab shows its name, so many tabs still fit.
                if selected {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, selected ? 13 : 10)
            .frame(height: 30)
            .foregroundStyle(selected || hovering ? .white : .white.opacity(0.7))
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.17))
                        .overlay(Capsule().stroke(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06)],
                                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .matchedGeometryEffect(id: "selectedTab", in: space)
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { hovering = $0 }
    }
}

/// Home: one card per enabled module that offers one.
struct HomeView: View {
    let vm: NotchViewModel
    let registry: ModuleRegistry

    var body: some View {
        if Appearance.shared.homeLayout == .compact {
            CompactHome(registry: registry)
        } else {
            HomeFeed(vm: vm, registry: registry)
        }
    }
}

/// A short message that needs you, with up to two buttons.
struct AlertView: View {
    let alert: NotchAlert
    let topInset: CGFloat
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Orbit hops with its ring glowing in the alert's colour; the alert's icon sits beside it.
            OrbitView(size: 50, mood: .wide, motion: .nudge, tint: alert.tint)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: alert.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(alert.tint))
                        .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1.5))
                        .offset(x: 2, y: 0)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 14, weight: .semibold))
                Text(alert.subtitle).font(.system(size: 12)).foregroundStyle(Tokens.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(alert.actions, id: \.title) { action in
                if action.isPrimary || action.tint != nil {
                    Button(action.title) { action.perform?(); dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(action.tint ?? Color.white))
                        .foregroundStyle(action.tint == nil ? Color.black : Color.white)
                } else {
                    GlassPillButton(title: action.title) { action.perform?(); dismiss() }
                }
            }
        }
        .padding(.top, topInset + 6)
        .padding([.horizontal, .bottom], 18)
    }
}

/// Shown while a file is dragged over the notch: keep it, convert it, or AirDrop it.
struct DropZonesView: View {
    let vm: NotchViewModel
    let shelf: ShelfModule

    var body: some View {
        HStack(spacing: 10) {
            DropZone(title: "Keep on Shelf", subtitle: "Drag it out later", symbol: "tray.and.arrow.down.fill") { urls in
                shelf.add(urls)
                openShelf()
            }
            .frame(maxWidth: .infinity)
            DropZone(title: "Convert", subtitle: "Image · video · audio", symbol: "arrow.triangle.2.circlepath") { urls in
                shelf.askToConvert(urls)
                openShelf()
            }
            .frame(width: 140)
            DropZone(title: "AirDrop", subtitle: "Nearby devices", symbol: "paperplane.fill") { urls in
                vm.close()
                shelf.airDrop(urls)
            }
            .frame(width: 140)
        }
        .padding(.top, vm.notchSize.height + 8)
        .padding([.horizontal, .bottom], 14)
    }

    private func openShelf() {
        vm.selectedTab = shelf.id
        vm.state = .open
    }

    struct DropZone: View {
        let title: String
        let subtitle: String
        let symbol: String
        let onDrop: @MainActor ([URL]) -> Void
        @State private var targeted = false

        var body: some View {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Tokens.secondary)
            }
            .foregroundStyle(targeted ? .white : Tokens.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), selected: targeted)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(targeted ? 0.6 : 0), lineWidth: 1.5))
            .scaleEffect(targeted ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let handler = onDrop
                return ShelfModule.readURLs(providers, then: handler)
            }
        }
    }
}

/// Peek while presenting: just a quiet label, nothing private.
struct PresentingPeek: View {
    let vm: NotchViewModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").font(.system(size: 12))
            Text("Presenting").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Tokens.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Open panel while presenting: everything else stays hidden until you stop.
struct PresentingPanel: View {
    let vm: NotchViewModel
    var body: some View {
        NotchCard {
            VStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.system(size: 24)).foregroundStyle(Tokens.secondary)
                Text("Presenting").font(.system(size: 15, weight: .semibold))
                Text("Notch content and pop-ups are hidden.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                PillButton(title: "Stop presenting") { vm.presenting = false }
                Text("⌥P switches Presenting on and off.").font(.system(size: 11)).foregroundStyle(Tokens.faint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Compact Home: one line per thing going on, like the peek chips but all of them.
struct CompactHome: View {
    let registry: ModuleRegistry

    var body: some View {
        let chips = registry.enabled.compactMap(\.peekChip).sorted { $0.priority > $1.priority }
        NotchCard {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                if chips.isEmpty {
                    Spacer()
                    Text("All clear").font(.system(size: 15, weight: .semibold))
                    Text("Nothing needs you right now.").font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                    Spacer()
                } else {
                    ForEach(chips) { chip in
                        HStack(spacing: 10) {
                            Image(systemName: chip.symbol).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(chip.tint).frame(width: 18)
                            Text(chip.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.surface2))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Shown while a web link (e.g. a YouTube video from the browser) is dragged over the notch.
struct LinkDropView: View {
    let vm: NotchViewModel
    let youtube: YouTubeModule
    @State private var targeted = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 18))
            Text("Play in notch").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(message ?? "Drop a YouTube link").font(.system(size: 11)).foregroundStyle(Tokens.secondary)
        }
        .foregroundStyle(targeted ? .white : Tokens.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(targeted ? Color.white.opacity(0.1) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(targeted ? .white : Tokens.faint))
        .padding(.top, vm.notchSize.height + 8)
        .padding([.horizontal, .bottom], 14)
        .onDrop(of: [.url, .plainText], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            let play: @MainActor (String) -> Void = { link in
                if youtube.play(link) { vm.state = .open; vm.selectedTab = youtube.id }
                else { message = "That's not a YouTube link"; vm.close() }
            }
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    let link = url?.absoluteString ?? ""
                    Task { @MainActor in play(link) }
                }
            } else {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    let link = text ?? ""
                    Task { @MainActor in play(link) }
                }
            }
            return true
        }
    }
}
