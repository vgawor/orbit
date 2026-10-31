import SwiftUI

/// Settings → Add-ons: everything Orbit can do in one gallery. Built-in features are on by
/// default; add-ons are added from the categories; community add-ons come from developers.
/// Pin the ones you use most to the tab bar; the rest open from the Add-ons tab in the notch.
struct AddOnsSettings: View {
    let registry: ModuleRegistry
    @State private var section: Section = .all
    @State private var entitlements = Entitlements.shared

    enum Section: Hashable {
        case all, tabBar, builtIn, community
        case category(AddOnCategory)

        var title: String {
            switch self {
            case .all: "Everything"
            case .tabBar: "Tab bar"
            case .builtIn: "Built-in"
            case .community: "Community"
            case .category(let c): c.title
            }
        }

        var blurb: String {
            switch self {
            case .all: "Built-in features are on already. Add the add-ons you want; they open from the Add-ons tab in the notch, or pin them to the tab bar."
            case .tabBar: "Up to \(ModuleRegistry.maxPinned) tabs fit in the tab bar. Everything else opens from the Add-ons tab."
            case .builtIn: "What Orbit does out of the box. Turn off what you don't use."
            case .community: "Add-ons made by other developers, from a small script in any language."
            case .category(let c): c.blurb
            }
        }
    }

    private var builtIns: [any NotchModule] { registry.all.filter { !($0 is any AddOnModule) } }
    private func isCommunity(_ m: any AddOnModule) -> Bool { m.addOn.author != "Orbit" }

    private var shown: [any NotchModule] {
        switch section {
        case .all: builtIns + registry.addOns.map { $0 as any NotchModule }
        case .tabBar: []
        case .builtIn: builtIns
        case .community: registry.addOns.filter(isCommunity)
        case .category(let c): registry.addOns.filter { $0.addOn.category == c && !isCommunity($0) }
        }
    }

    var body: some View {
        @Bindable var entitlements = entitlements
        HStack(spacing: 0) {
            List(selection: $section) {
                Label("Everything", systemImage: "square.grid.2x2").tag(Section.all)
                Label("Tab bar", systemImage: "pin").tag(Section.tabBar)
                SwiftUI.Section("Orbit") {
                    row(.builtIn, symbol: "circle.circle.fill", tint: .secondary, count: builtIns.count)
                }
                SwiftUI.Section("Add-ons") {
                    ForEach(AddOnCategory.allCases) { c in
                        row(.category(c), symbol: c.symbol, tint: c.tint,
                            count: registry.addOns.filter { $0.addOn.category == c && !isCommunity($0) }.count)
                    }
                    row(.community, symbol: "person.2.fill", tint: .teal, count: registry.addOns.filter(isCommunity).count)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.title2.bold())
                        Text(section.blurb).foregroundStyle(.secondary)
                    }
                    if section == .tabBar {
                        tabBarList
                    } else {
                        if shown.isEmpty { emptyNote }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(shown, id: \.id) { card($0) }
                        }
                    }
                    Divider().padding(.vertical, 6)
                    Toggle("Preview as Free (hides Pro add-ons, like a Free user sees it)", isOn: $entitlements.previewAsFree)
                    Text("Make your own: a community add-on is a small script in any language. See docs/SDK.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
    }

    private func row(_ s: Section, symbol: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(s.title)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: { Image(systemName: symbol).foregroundStyle(tint) }
        .tag(s)
    }

    @ViewBuilder private var emptyNote: some View {
        if section == .community {
            Text("No community add-ons yet. Put one in ~/Library/Application Support/Orbit/Widgets, or try the examples in sdk/examples.")
                .foregroundStyle(.secondary).padding(.top, 10)
        } else {
            Text("Nothing here yet.").foregroundStyle(.secondary).padding(.top, 20)
        }
    }

    // MARK: Tab bar

    private var tabBarList: some View {
        let pinned = registry.pinnedTabs
        return VStack(alignment: .leading, spacing: 0) {
            if pinned.isEmpty {
                Text("Nothing pinned. Pin add-ons from their cards, or right-click one in the notch's Add-ons tab.")
                    .foregroundStyle(.secondary).padding(12)
            }
            ForEach(Array(pinned.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 10) {
                    icon(m, size: 26)
                    Text(m.title)
                    Spacer()
                    Button { registry.movePinned(m.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0).help("Move left")
                    Button { registry.movePinned(m.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == pinned.count - 1).help("Move right")
                    Button("Unpin") { registry.setPinned(m.id, false) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 8)
                if i < pinned.count - 1 { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Cards

    private func icon(_ module: any NotchModule, size: CGFloat = 34) -> some View {
        let tint = (module as? any AddOnModule)?.addOn.category.tint ?? Color.gray
        return Image(systemName: module.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.gradient))
    }

    private func card(_ module: any NotchModule) -> some View {
        let addOn = module as? any AddOnModule
        let on = registry.isEnabled(module.id)
        let allowed = addOn.map { Entitlements.shared.allows($0.addOn.tier) } ?? true
        let subtitle: String = {
            guard let info = addOn?.addOn else { return "Built-in" }
            return info.author == "Orbit" ? info.category.title : "\(info.category.title) · by \(info.author)"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon(module)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                badge(addOn?.addOn.tier)
            }
            Text(addOn?.addOn.summary ?? Self.builtInSummary[module.id] ?? "Part of Orbit.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                if on && module.showsTab { pinToggle(module) }
                Spacer()
                if allowed {
                    Button(addOn == nil ? (on ? "Turn off" : "Turn on") : (on ? "Remove" : "Add")) {
                        registry.setEnabled(module.id, !on)
                    }
                    .buttonStyle(.borderedProminent).tint(on ? .gray : .accentColor).controlSize(.small)
                } else {
                    Button("Upgrade to Pro") {
                        // Signed in: straight to checkout. Otherwise to the Orbit account section.
                        if OrbitCloud.shared.isSignedIn { Task { await OrbitCloud.shared.upgrade() } }
                        else { SettingsView.show(.accounts) }
                    }
                    .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                    .help("Pro add-ons come with Orbit Pro · $12/month")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private func pinToggle(_ module: any NotchModule) -> some View {
        let pinned = registry.isPinned(module.id)
        return Button {
            registry.setPinned(module.id, !pinned)
        } label: {
            Label(pinned ? "In tab bar" : "Pin to tab bar", systemImage: pinned ? "pin.fill" : "pin")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(!pinned && registry.pinsFull)
        .help(!pinned && registry.pinsFull ? "The tab bar is full: unpin a tab first" : pinned ? "Unpin from the tab bar" : "Show it in the tab bar")
    }

    @ViewBuilder private func badge(_ tier: AddOnTier?) -> some View {
        let (text, color): (String, Color) = switch tier {
        case .none: ("Built-in", .gray)
        case .some(.pro): ("Pro", .purple)
        case .some(.free): ("Free", .green)
        }
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }

    /// One line for each built-in feature, for its card.
    static let builtInSummary: [String: String] = [
        "music": "What's playing in Spotify or Music, with play, pause and skip.",
        "meetings": "Your next meeting from Calendar, with one-click Join for Zoom, Meet and Teams.",
        "tasks": "Your to-dos on this Mac and in HubSpot, with due dates and reminders.",
        "focus": "Pomodoro and timers, with focus music if you like.",
        "notes": "Quick notes, always one click away.",
        "shelf": "Drop files on the notch to keep them handy, AirDrop them or convert them.",
        "capture": "Screenshots and screen recordings, including scrolling screenshots.",
        "agents": "Start Claude Code on a task and approve each step from the notch.",
        "ask": "Type a command: start a timer, add a task, join a meeting and more (⌥K).",
        "smart": "Claude answers questions about your day and writes your morning brief.",
        "youtube": "Watch a video in a small floating player.",
        "prompter": "A teleprompter under the camera for calls and recordings.",
        "mirror": "Check how you look before a call.",
        "mic": "Mute and unmute your mic from anywhere (⌥M).",
        "ssh": "Your SSH hosts, one click to connect.",
        "photos": "Your latest photos, ready to drag into anything.",
        "draw": "Draw on top of your screen while you present (⌃⌥D).",
    ]
}
