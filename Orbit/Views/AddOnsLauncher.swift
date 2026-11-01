import SwiftUI

/// The Add-ons tab: everything you've turned on that isn't pinned to the tab bar, as a grid of
/// icons grouped like the Add-ons gallery. Click to open; right-click or the pin to pin it.
struct AddOnsLauncher: View {
    static let tabID = "launcher"

    let vm: NotchViewModel
    let registry: ModuleRegistry

    private struct Group: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let modules: [any NotchModule]
    }

    private var groups: [Group] {
        let tabs = registry.launcherTabs
        var out: [Group] = []
        let builtIn = tabs.filter { !($0 is any AddOnModule) }
        if !builtIn.isEmpty { out.append(Group(id: "builtin", title: "Built-in", tint: .white, modules: builtIn)) }
        for c in AddOnCategory.allCases {
            let mods = tabs.filter { ($0 as? any AddOnModule)?.addOn.category == c }
            if !mods.isEmpty { out.append(Group(id: c.rawValue, title: c.title, tint: c.tint, modules: mods)) }
        }
        return out
    }

    var body: some View {
        let groups = self.groups
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                OrbitView(size: 30, mood: .happy, motion: .idle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add-ons").font(.system(size: 15, weight: .semibold))
                    Text(groups.isEmpty ? "Nothing here yet" : "Click to open. Right-click to pin to the tab bar.")
                        .font(.system(size: 11.5)).foregroundStyle(Tokens.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                SettingsLink {
                    Label("Get more", systemImage: "plus").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassSurface(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    SettingsView.show(.addOns)
                    SettingsWindow.willOpen()
                })
            }
            if groups.isEmpty {
                empty
            } else {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { g in section(g) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ g: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(g.id == "builtin" ? Tokens.secondary : g.tint.opacity(0.9))
                .padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                ForEach(g.modules, id: \.id) { m in
                    LauncherTile(module: m, tint: g.tint, registry: registry) { vm.selectedTab = m.id }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            OrbitView(size: 64, mood: .wink, motion: .idle)
            Text("Add-ons you add show up here").font(.system(size: 14, weight: .semibold))
            Text("Pick from 35 add-ons in Settings → Add-ons: water reminders, weather, a game, dev tools and more.")
                .font(.system(size: 12)).foregroundStyle(Tokens.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(24)
    }
}

private struct LauncherTile: View {
    let module: any NotchModule
    let tint: Color
    let registry: ModuleRegistry
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: module.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint == .white ? Color.white.opacity(0.14) : tint.opacity(0.55)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let chip = module.peekChip {
                        Text(chip.text).font(.system(size: 10.5)).foregroundStyle(chip.tint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if hovering && !registry.pinsFull {
                    Button { registry.setPinned(module.id, true) } label: {
                        Image(systemName: "pin").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tokens.secondary).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Pin to tab bar")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if registry.pinsFull {
                Text("Tab bar is full: unpin a tab first")
            } else {
                Button("Pin to tab bar") { registry.setPinned(module.id, true) }
            }
            if module is any AddOnModule {
                Button("Remove add-on") { registry.setEnabled(module.id, false) }
            } else {
                Button("Turn off") { registry.setEnabled(module.id, false) }
            }
        }
    }
}
