import SwiftUI

/// Settings → Appearance: Orbit, greeting, Home layout and cards, music style.
struct AppearanceSettings: View {
    let registry: ModuleRegistry
    @State private var look = Appearance.shared

    var body: some View {
        @Bindable var look = look
        Form {
            Section("Orbit") {
                HStack(spacing: 14) {
                    ForEach(Appearance.companions) { c in
                        Button { look.companionID = c.id } label: {
                            VStack(spacing: 4) {
                                OrbitView(size: 40, mood: look.companionID == c.id ? .happy : .normal,
                                          motion: look.companionID == c.id ? .idle : .still, colors: c)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.85)))
                                    .overlay(Circle().stroke(look.companionID == c.id ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                                Text(c.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextField("Greeting name", text: $look.greetingName)
                Text("Shown as “\(look.greeting)”.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Panel") {
                Picker("Look", selection: $look.panelStyle) {
                    ForEach(Appearance.PanelStyle.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(look.panelStyle == .glass
                     ? "The panel is dark glass below a black top that blends with the notch."
                     : "The panel is solid black, like the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Home") {
                Picker("Layout", selection: $look.homeLayout) {
                    ForEach(Appearance.HomeLayout.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if look.homeLayout == .compact {
                    Text("A list of everything going on: meetings, tasks, focus, music, Claude.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if look.homeLayout == .feed {
                Section("Home widgets") {
                    ForEach(orderedWidgets, id: \.self) { w in
                        HStack {
                            Toggle(w.name, isOn: Binding(
                                get: { look.homeWidgets.contains(w.rawValue) },
                                set: { on in
                                    if on { look.homeWidgets.append(w.rawValue) } else { look.homeWidgets.removeAll { $0 == w.rawValue } }
                                }))
                            Spacer()
                            if let i = look.homeWidgets.firstIndex(of: w.rawValue) {
                                Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.borderless).disabled(i == 0)
                                Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.borderless).disabled(i == look.homeWidgets.count - 1)
                            }
                        }
                    }
                    Button("Reset to default order") {
                        look.homeWidgets = Appearance.Widget.allCases.filter { $0 != .photos }.map(\.rawValue)
                    }
                }

                Section("Add-on widgets") {
                    let withWidgets = registry.enabled.filter { $0 is any AddOnModule && $0.homeCard != nil }
                    if withWidgets.isEmpty {
                        Text("Add-ons you add can put a widget on Home. Add some in Settings → Add-ons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(withWidgets, id: \.id) { m in
                        Toggle(isOn: Binding(
                            get: { !look.hiddenAddOnWidgets.contains(m.id) },
                            set: { on in
                                look.hiddenAddOnWidgets.removeAll { $0 == m.id }
                                if !on { look.hiddenAddOnWidgets.append(m.id) }
                            })) { Label(m.title, systemImage: m.symbol) }
                    }
                }

                Section("Shortcuts") {
                    ForEach(look.shortcuts, id: \.self) { item in
                        HStack {
                            Text(item.hasPrefix("/") ? URL(fileURLWithPath: item).deletingPathExtension().lastPathComponent : item)
                            Spacer()
                            Button { look.shortcuts.removeAll { $0 == item } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add a web link (https://…)", text: $newLink)
                            .onSubmit(addLink)
                        Button("Add", action: addLink).disabled(URL(string: newLink)?.scheme == nil)
                    }
                    Text("Use the + tile on Home to add an app.").font(.caption).foregroundStyle(.secondary)
                }

                Section("Countdown") {
                    TextField("Count down to (e.g. Launch day)", text: $look.countdownTitle)
                    DatePicker("Date", selection: $look.countdownDate, displayedComponents: [.date])
                    Text("Leave the name empty to count down to your next task that's due.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Music") {
                Picker("Artwork", selection: $look.musicStyle) {
                    ForEach(Appearance.MusicStyle.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    @State private var newLink = ""

    /// Shown widgets first (in their order), then the hidden ones.
    private var orderedWidgets: [Appearance.Widget] {
        let shown = look.widgets
        return shown + Appearance.Widget.allCases.filter { !shown.contains($0) }
    }

    private func move(_ i: Int, _ by: Int) {
        let j = i + by
        guard look.homeWidgets.indices.contains(j) else { return }
        look.homeWidgets.swapAt(i, j)
    }

    private func addLink() {
        let link = newLink.trimmingCharacters(in: .whitespaces)
        guard URL(string: link)?.scheme != nil, !look.shortcuts.contains(link) else { return }
        look.shortcuts.append(link)
        newLink = ""
    }
}
